#!/usr/bin/env bash
# Produces a self-contained backup package per node:
#   cassandra_backup_<HOSTNAME>_<TIMESTAMP>.tar.gz
# Contents: CQL schema + SSTable snapshot files + manifest.
# Cohesity picks up COHESITY_PICKUP_DIR – no direct integration needed.
# Schedule: daily at 01:00  →  cron: 0 1 * * *
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

CQLSH_HOST="${CQLSH_HOST:-127.0.0.1}"
CQLSH_PORT="${CQLSH_PORT:-9042}"
DATA_DIR="${DATA_DIR:-/datos/dse-data}"
DSE_VERSION="${DSE_VERSION:-6.8.36}"
COHESITY_PICKUP_DIR="${COHESITY_PICKUP_DIR:-/mnt/cohesity_pickup/cassandra/daily}"
WORK_BASE_DIR="${WORK_BASE_DIR:-/datos/backup_staging}"
LOG_FILE="${LOG_DIR}/daily_snapshot.log"
RETENTION_DAYS="${RETENTION_DAYS:-30}"

exec >> "${LOG_FILE}" 2>&1

HOSTNAME_SHORT=$(hostname -s)
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
SNAPSHOT_TAG="daily_${TIMESTAMP}"
PACKAGE_NAME="cassandra_backup_${HOSTNAME_SHORT}_${TIMESTAMP}"
WORK_DIR="${WORK_BASE_DIR}/${PACKAGE_NAME}"

log "INFO" "=== Daily backup started: ${PACKAGE_NAME} ==="
check_cassandra_alive
mkdir -p "${WORK_DIR}/schema" "${WORK_DIR}/data" "${COHESITY_PICKUP_DIR}"

# ── 1. EXPORT CQL SCHEMA ─────────────────────────────────────────────────────
# Schema must be exported before the snapshot so both are consistent.
log "INFO" "Exporting CQL schema..."
cqlsh "${CQLSH_HOST}" "${CQLSH_PORT}" \
    --execute "DESCRIBE FULL SCHEMA;" \
    > "${WORK_DIR}/schema/schema.cql"
log "INFO" "Schema exported ($(wc -l < "${WORK_DIR}/schema/schema.cql") lines)"

# ── 2. FLUSH MEMTABLES ───────────────────────────────────────────────────────
# Ensures all in-memory writes are persisted to SSTables before snapshotting.
log "INFO" "Flushing memtables..."
nodetool flush

# ── 3. TAKE SNAPSHOT ─────────────────────────────────────────────────────────
nodetool clearsnapshot --all 2>/dev/null || true
log "INFO" "Taking snapshot '${SNAPSHOT_TAG}'..."
nodetool snapshot --tag "${SNAPSHOT_TAG}"

# ── 4. COPY SNAPSHOT SSTABLES ────────────────────────────────────────────────
# SSTables are the binary data files Cassandra uses on disk.
# Directory layout: DATA_DIR/<keyspace>/<table>-<uuid>/snapshots/<tag>/*.db
log "INFO" "Copying SSTable files..."
FILE_COUNT=0
while IFS= read -r -d '' snap_dir; do
    keyspace=$(echo "${snap_dir}" | awk -F'/' '{print $(NF-3)}')
    table_uuid=$(echo "${snap_dir}" | awk -F'/' '{print $(NF-2)}')
    # Strip the UUID suffix from the table directory name for readability
    table="${table_uuid%-*}"
    dest="${WORK_DIR}/data/${keyspace}/${table_uuid}"
    mkdir -p "${dest}"
    cp -a "${snap_dir}/." "${dest}/"
    FILE_COUNT=$((FILE_COUNT + $(find "${snap_dir}" -maxdepth 1 -type f | wc -l)))
done < <(find "${DATA_DIR}" -type d -name "${SNAPSHOT_TAG}" -print0)
log "INFO" "Copied ${FILE_COUNT} SSTable file(s)"

# ── 5. CLEAR IN-PLACE SNAPSHOT ───────────────────────────────────────────────
nodetool clearsnapshot --tag "${SNAPSHOT_TAG}"
log "INFO" "In-place Cassandra snapshot cleared"

# ── 6. WRITE MANIFEST ────────────────────────────────────────────────────────
KEYSPACES=$(get_user_keyspaces "${CQLSH_HOST}" "${CQLSH_PORT}" | paste -sd ',' -)
cat > "${WORK_DIR}/manifest.json" <<EOF
{
  "backup_type": "daily_snapshot",
  "hostname": "${HOSTNAME_SHORT}",
  "timestamp": "${TIMESTAMP}",
  "snapshot_tag": "${SNAPSHOT_TAG}",
  "dse_version": "${DSE_VERSION}",
  "keyspaces": "${KEYSPACES}",
  "sstable_files": ${FILE_COUNT},
  "schema_file": "schema/schema.cql"
}
EOF

# ── 7. PACKAGE INTO TAR.GZ ───────────────────────────────────────────────────
PACKAGE_FILE="${COHESITY_PICKUP_DIR}/${PACKAGE_NAME}.tar.gz"
log "INFO" "Creating package → ${PACKAGE_FILE}"
tar -czf "${PACKAGE_FILE}" -C "${WORK_BASE_DIR}" "${PACKAGE_NAME}"
sha256sum "${PACKAGE_FILE}" > "${PACKAGE_FILE}.sha256"
log "INFO" "Package size: $(du -sh "${PACKAGE_FILE}" | cut -f1)"
log "INFO" "SHA-256: $(cat "${PACKAGE_FILE}.sha256")"

# ── 8. CLEANUP & RETENTION ───────────────────────────────────────────────────
rm -rf "${WORK_DIR}"
find "${COHESITY_PICKUP_DIR}" -name "cassandra_backup_*.tar.gz" \
    -mtime "+${RETENTION_DAYS}" -delete
find "${COHESITY_PICKUP_DIR}" -name "cassandra_backup_*.tar.gz.sha256" \
    -mtime "+${RETENTION_DAYS}" -delete
log "INFO" "Purged packages older than ${RETENTION_DAYS} days"

log "INFO" "=== Daily backup completed: ${PACKAGE_FILE} ==="
