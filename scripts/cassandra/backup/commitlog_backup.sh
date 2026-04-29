#!/usr/bin/env bash
# Packages sealed commit log segments into a tar.gz for Cohesity pickup.
# Enables point-in-time recovery (PITR) when combined with a daily snapshot.
# Schedule: every hour  →  cron: 0 * * * *  →  RPO ≈ 1 hour
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

COMMITLOG_DIR="${COMMITLOG_DIR:-/datos/dse-data/commitlog}"
COHESITY_PICKUP_DIR="${COHESITY_PICKUP_DIR:-/datos/backup/cohesity_pickup/commitlogs}"
WORK_BASE_DIR="${WORK_BASE_DIR:-/datos/backup_staging}"
LOG_FILE="${LOG_DIR}/commitlog_backup.log"
RETENTION_DAYS="${RETENTION_DAYS:-30}"

exec >> "${LOG_FILE}" 2>&1

HOSTNAME_SHORT=$(hostname -s)
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
PACKAGE_NAME="cassandra_commitlog_${HOSTNAME_SHORT}_${TIMESTAMP}"
WORK_DIR="${WORK_BASE_DIR}/${PACKAGE_NAME}"

log "INFO" "=== Commit log backup started: ${TIMESTAMP} ==="
check_cassandra_alive
mkdir -p "${WORK_DIR}" "${COHESITY_PICKUP_DIR}"

# Roll the active commit log segment so the latest writes end up in a sealed
# (.log) file rather than the in-progress segment that is still being written.
log "INFO" "Rolling active commit log segment..."
"${NODETOOL}" flush

# Copy only sealed segments (CommitLog-<version>-<id>.log).
# The active/in-progress segment has no .log extension or is still open.
COPIED=0
while IFS= read -r -d '' clog_file; do
    cp "${clog_file}" "${WORK_DIR}/"
    COPIED=$((COPIED + 1))
done < <(find "${COMMITLOG_DIR}" -maxdepth 1 -name "CommitLog-*.log" -print0)

log "INFO" "Staged ${COPIED} commit log segment(s)"

cat > "${WORK_DIR}/manifest.json" <<EOF
{
  "backup_type": "commitlog",
  "hostname": "${HOSTNAME_SHORT}",
  "timestamp": "${TIMESTAMP}",
  "segments": ${COPIED}
}
EOF

# Package and place in Cohesity pickup directory
PACKAGE_FILE="${COHESITY_PICKUP_DIR}/${PACKAGE_NAME}.tar.gz"
tar -czf "${PACKAGE_FILE}" -C "${WORK_BASE_DIR}" "${PACKAGE_NAME}"
sha256sum "${PACKAGE_FILE}" > "${PACKAGE_FILE}.sha256"
log "INFO" "Package → ${PACKAGE_FILE} ($(du -sh "${PACKAGE_FILE}" | cut -f1))"

rm -rf "${WORK_DIR}"

# Purge packages older than retention period
find "${COHESITY_PICKUP_DIR}" -name "cassandra_commitlog_*.tar.gz" \
    -mtime "+${RETENTION_DAYS}" -delete
find "${COHESITY_PICKUP_DIR}" -name "cassandra_commitlog_*.tar.gz.sha256" \
    -mtime "+${RETENTION_DAYS}" -delete
log "INFO" "Purged commit log packages older than ${RETENTION_DAYS} days"

log "INFO" "=== Commit log backup completed ==="
