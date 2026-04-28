#!/usr/bin/env bash
# Creates a long-term archival package: full snapshot + CQL schema.
# Schedule: January 1 and July 1 at 02:00  →  cron: 0 2 1 1,7 *
# Retention: 10 years (managed by storage policy on the archive target).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

CQLSH_HOST="${CQLSH_HOST:-127.0.0.1}"
CQLSH_PORT="${CQLSH_PORT:-9042}"
DATA_DIR="${DATA_DIR:-/var/lib/cassandra/data}"
ARCHIVE_BASE_DIR="${ARCHIVE_BASE_DIR:-/mnt/longterm_archive/cassandra}"
LOG_FILE="${LOG_DIR}/semiannual_archive.log"

exec >> "${LOG_FILE}" 2>&1

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ARCHIVE_TAG="archive_${TIMESTAMP}"
WORK_DIR="${ARCHIVE_BASE_DIR}/${ARCHIVE_TAG}"

log "INFO" "=== Semiannual archive started: ${ARCHIVE_TAG} ==="
check_cassandra_alive

mkdir -p "${WORK_DIR}/data" "${WORK_DIR}/schema"

# 1 – Export CQL schema
SCHEMA_FILE="${WORK_DIR}/schema/schema_${TIMESTAMP}.cql"
log "INFO" "Exporting full CQL schema..."
cqlsh "${CQLSH_HOST}" "${CQLSH_PORT}" \
    --execute "DESCRIBE FULL SCHEMA;" \
    > "${SCHEMA_FILE}"
gzip "${SCHEMA_FILE}"
log "INFO" "Schema saved: ${SCHEMA_FILE}.gz"

# 2 – Take a named snapshot
log "INFO" "Flushing memtables..."
nodetool flush

log "INFO" "Taking archive snapshot '${ARCHIVE_TAG}'..."
nodetool snapshot --tag "${ARCHIVE_TAG}"

# 3 – Export snapshot data
log "INFO" "Exporting snapshot data..."
while IFS= read -r -d '' snap_dir; do
    keyspace=$(echo "${snap_dir}" | awk -F'/' '{print $(NF-3)}')
    table=$(echo "${snap_dir}"    | awk -F'/' '{print $(NF-2)}')
    dest="${WORK_DIR}/data/${keyspace}/${table}"
    mkdir -p "${dest}"
    cp -a "${snap_dir}/." "${dest}/"
done < <(find "${DATA_DIR}" -type d -name "${ARCHIVE_TAG}" -print0)

# 4 – Clear in-place snapshot
nodetool clearsnapshot --tag "${ARCHIVE_TAG}"
log "INFO" "In-place snapshot cleared"

# 5 – Create a single compressed archive for long-term storage
ARCHIVE_FILE="${ARCHIVE_BASE_DIR}/${ARCHIVE_TAG}.tar.gz"
log "INFO" "Compressing archive → ${ARCHIVE_FILE}"
tar -czf "${ARCHIVE_FILE}" -C "${ARCHIVE_BASE_DIR}" "${ARCHIVE_TAG}"
rm -rf "${WORK_DIR}"

# 6 – Generate SHA-256 checksum for integrity verification
sha256sum "${ARCHIVE_FILE}" > "${ARCHIVE_FILE}.sha256"
log "INFO" "Checksum: $(cat "${ARCHIVE_FILE}.sha256")"

# Retention (10 years) is enforced by the Cohesity/storage policy, not this script.
log "INFO" "=== Semiannual archive completed: ${ARCHIVE_FILE} ==="
