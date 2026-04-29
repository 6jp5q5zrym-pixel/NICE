#!/usr/bin/env bash
# Semiannual long-term archive: full snapshot + CQL schema in one tar.gz.
# Schedule: January 1 and July 1 at 02:00  →  cron: 0 2 1 1,7 *
# Retention: 10 years (enforced by Cohesity storage policy, not this script).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

CQLSH_HOST="${CQLSH_HOST:-127.0.0.1}"
CQLSH_PORT="${CQLSH_PORT:-9042}"
DATA_DIR="${DATA_DIR:-/datos/dse-data}"
DSE_VERSION="${DSE_VERSION:-6.8.36}"
COHESITY_PICKUP_DIR="${COHESITY_PICKUP_DIR:-/datos/backup/cohesity_pickup/archive}"
WORK_BASE_DIR="${WORK_BASE_DIR:-/datos/backup_staging}"
LOG_FILE="${LOG_DIR}/semiannual_archive.log"

exec >> "${LOG_FILE}" 2>&1

HOSTNAME_SHORT=$(hostname -s)
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
SNAPSHOT_TAG="archive_${TIMESTAMP}"
PACKAGE_NAME="cassandra_archive_${HOSTNAME_SHORT}_${TIMESTAMP}"
WORK_DIR="${WORK_BASE_DIR}/${PACKAGE_NAME}"

log "INFO" "=== Semiannual archive started: ${PACKAGE_NAME} ==="
check_cassandra_alive
mkdir -p "${WORK_DIR}/schema" "${WORK_DIR}/data" "${COHESITY_PICKUP_DIR}"

# 1 – Export schema
log "INFO" "Exporting CQL schema..."
"${CQLSH}" "${CQLSH_HOST}" "${CQLSH_PORT}" \
    --execute "DESCRIBE FULL SCHEMA;" \
    > "${WORK_DIR}/schema/schema.cql"

# 2 – Flush + snapshot
log "INFO" "Flushing memtables..."
"${NODETOOL}" flush
"${NODETOOL}" clearsnapshot --all 2>/dev/null || true
log "INFO" "Taking snapshot '${SNAPSHOT_TAG}'..."
"${NODETOOL}" snapshot --tag "${SNAPSHOT_TAG}"

# 3 – Copy SSTable files
FILE_COUNT=0
while IFS= read -r -d '' snap_dir; do
    keyspace=$(echo "${snap_dir}" | awk -F'/' '{print $(NF-3)}')
    table_uuid=$(echo "${snap_dir}" | awk -F'/' '{print $(NF-2)}')
    dest="${WORK_DIR}/data/${keyspace}/${table_uuid}"
    mkdir -p "${dest}"
    cp -a "${snap_dir}/." "${dest}/"
    FILE_COUNT=$((FILE_COUNT + $(find "${snap_dir}" -maxdepth 1 -type f | wc -l)))
done < <(find "${DATA_DIR}" -type d -name "${SNAPSHOT_TAG}" -print0)

"${NODETOOL}" clearsnapshot --tag "${SNAPSHOT_TAG}"
log "INFO" "Snapshot copied (${FILE_COUNT} files), in-place snapshot cleared"

# 4 – Manifest
KEYSPACES=$(get_user_keyspaces "${CQLSH_HOST}" "${CQLSH_PORT}" | paste -sd ',' -)
cat > "${WORK_DIR}/manifest.json" <<EOF
{
  "backup_type": "semiannual_archive",
  "hostname": "${HOSTNAME_SHORT}",
  "timestamp": "${TIMESTAMP}",
  "snapshot_tag": "${SNAPSHOT_TAG}",
  "dse_version": "${DSE_VERSION}",
  "keyspaces": "${KEYSPACES}",
  "sstable_files": ${FILE_COUNT},
  "schema_file": "schema/schema.cql",
  "retention_years": 10
}
EOF

# 5 – Package
PACKAGE_FILE="${COHESITY_PICKUP_DIR}/${PACKAGE_NAME}.tar.gz"
log "INFO" "Compressing archive → ${PACKAGE_FILE}"
tar -czf "${PACKAGE_FILE}" -C "${WORK_BASE_DIR}" "${PACKAGE_NAME}"
sha256sum "${PACKAGE_FILE}" > "${PACKAGE_FILE}.sha256"
log "INFO" "Size: $(du -sh "${PACKAGE_FILE}" | cut -f1)  |  SHA-256: $(cat "${PACKAGE_FILE}.sha256")"

rm -rf "${WORK_DIR}"
log "INFO" "=== Semiannual archive completed: ${PACKAGE_FILE} ==="
