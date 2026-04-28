#!/usr/bin/env bash
# Triggers a consistent Cassandra snapshot on all cluster nodes and exports
# the snapshot files to SNAPSHOT_EXPORT_DIR for Cohesity to pick up.
# Equivalent to a full backup – runs daily at 01:00.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

CQLSH_HOST="${CQLSH_HOST:-127.0.0.1}"
CQLSH_PORT="${CQLSH_PORT:-9042}"
DATA_DIR="${DATA_DIR:-/var/lib/cassandra/data}"
SNAPSHOT_EXPORT_DIR="${SNAPSHOT_EXPORT_DIR:-/var/lib/cassandra/snapshots_export}"
LOG_FILE="${LOG_DIR}/daily_snapshot.log"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
SNAPSHOT_PREFIX="${SNAPSHOT_PREFIX:-daily}"

exec >> "${LOG_FILE}" 2>&1

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
SNAPSHOT_TAG="${SNAPSHOT_PREFIX}_${TIMESTAMP}"
EXPORT_PATH="${SNAPSHOT_EXPORT_DIR}/${SNAPSHOT_TAG}"

log "INFO" "=== Daily snapshot started: ${SNAPSHOT_TAG} ==="
check_cassandra_alive

# Step 1 – flush memtables to disk before snapshotting
log "INFO" "Flushing memtables (nodetool flush)..."
nodetool flush

# Step 2 – clear any previous snapshot with same tag (safety measure)
nodetool clearsnapshot --all 2>/dev/null || true

# Step 3 – take a cluster-wide snapshot
# nodetool snapshot runs locally; Cohesity or an orchestrator must trigger this
# script on each node. The snapshot tag is identical across all nodes so
# restores can be coordinated by tag.
log "INFO" "Taking snapshot with tag '${SNAPSHOT_TAG}'..."
nodetool snapshot --tag "${SNAPSHOT_TAG}"

# Step 4 – export snapshot files out of the data directory so Cohesity can
# access them from a single well-known location
mkdir -p "${EXPORT_PATH}"
log "INFO" "Exporting snapshot files → ${EXPORT_PATH}"

while IFS= read -r -d '' snap_dir; do
    keyspace=$(echo "${snap_dir}" | awk -F'/' '{print $(NF-3)}')
    table=$(echo "${snap_dir}" | awk -F'/' '{print $(NF-2)}')
    dest="${EXPORT_PATH}/${keyspace}/${table}"
    mkdir -p "${dest}"
    cp -a "${snap_dir}/." "${dest}/"
done < <(find "${DATA_DIR}" -type d -name "${SNAPSHOT_TAG}" -print0)

# Optionally compress the export (disable if Cohesity deduplication is preferred)
if [[ "${COMPRESS_EXPORT:-false}" == "true" ]]; then
    log "INFO" "Compressing export..."
    tar -czf "${EXPORT_PATH}.tar.gz" -C "${SNAPSHOT_EXPORT_DIR}" "${SNAPSHOT_TAG}"
    rm -rf "${EXPORT_PATH}"
fi

# Step 5 – remove the in-place Cassandra snapshot to free disk space
log "INFO" "Clearing in-place snapshot '${SNAPSHOT_TAG}'..."
nodetool clearsnapshot --tag "${SNAPSHOT_TAG}"

# Step 6 – purge exports older than retention period
find "${SNAPSHOT_EXPORT_DIR}" -maxdepth 1 -name "${SNAPSHOT_PREFIX}_*" \
    -mtime "+${RETENTION_DAYS}" -exec rm -rf {} +
log "INFO" "Purged snapshot exports older than ${RETENTION_DAYS} days"

log "INFO" "=== Daily snapshot completed: ${SNAPSHOT_TAG} ==="
