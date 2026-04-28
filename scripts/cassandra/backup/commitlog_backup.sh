#!/usr/bin/env bash
# Copies active commit logs to a staging directory for Cohesity to ingest.
# Runs every hour – establishes RPO ≈ 1 hour.
# Cohesity picks up COMMITLOG_STAGING_DIR as part of its protection job.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

COMMITLOG_DIR="${COMMITLOG_DIR:-/var/lib/cassandra/commitlog}"
COMMITLOG_STAGING_DIR="${COMMITLOG_STAGING_DIR:-/var/lib/cassandra/commitlog_staging}"
LOG_FILE="${LOG_DIR}/commitlog_backup.log"
RETENTION_DAYS="${RETENTION_DAYS:-30}"

exec >> "${LOG_FILE}" 2>&1

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
STAGING_SUBDIR="${COMMITLOG_STAGING_DIR}/${TIMESTAMP}"

log "INFO" "=== Commit log backup started: ${TIMESTAMP} ==="
check_cassandra_alive

mkdir -p "${STAGING_SUBDIR}"

# Force Cassandra to roll the current commit log segment so the latest writes
# are in a sealed (complete) file rather than the in-progress segment.
log "INFO" "Rolling commit log segments..."
nodetool drain 2>/dev/null || nodetool flush

# Copy sealed commit log files (.log) to staging – excludes the active segment
# (which has no extension or is still being written) by relying on the .log suffix.
COPIED=0
while IFS= read -r -d '' clog_file; do
    cp "${clog_file}" "${STAGING_SUBDIR}/"
    COPIED=$((COPIED + 1))
done < <(find "${COMMITLOG_DIR}" -maxdepth 1 -name "CommitLog-*.log" -print0)

log "INFO" "Copied ${COPIED} commit log segment(s) → ${STAGING_SUBDIR}"

# Purge staging directories older than retention period
find "${COMMITLOG_STAGING_DIR}" -maxdepth 1 -mindepth 1 -type d \
    -mtime "+${RETENTION_DAYS}" -exec rm -rf {} +
log "INFO" "Purged commit log staging dirs older than ${RETENTION_DAYS} days"

log "INFO" "=== Commit log backup completed: ${TIMESTAMP} ==="
