#!/usr/bin/env bash
# Standalone schema export – produces schema_<HOSTNAME>_<TIMESTAMP>.cql.gz
# in COHESITY_PICKUP_DIR/schema/.
# The schema is also embedded inside daily_snapshot.sh packages, so this
# script is only needed for independent schema-only restores or audits.
# Schedule: daily at 00:50 (10 min before daily_snapshot.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

CQLSH_HOST="${CQLSH_HOST:-127.0.0.1}"
CQLSH_PORT="${CQLSH_PORT:-9042}"
COHESITY_PICKUP_DIR="${COHESITY_PICKUP_DIR:-/mnt/cohesity_pickup/cassandra/schema}"
LOG_FILE="${LOG_DIR}/schema_backup.log"
RETENTION_DAYS="${RETENTION_DAYS:-30}"

exec >> "${LOG_FILE}" 2>&1
mkdir -p "${COHESITY_PICKUP_DIR}"

HOSTNAME_SHORT=$(hostname -s)
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
SCHEMA_FILE="${COHESITY_PICKUP_DIR}/schema_${HOSTNAME_SHORT}_${TIMESTAMP}.cql"

log "INFO" "Exporting CQL schema → ${SCHEMA_FILE}.gz"
cqlsh "${CQLSH_HOST}" "${CQLSH_PORT}" \
    --execute "DESCRIBE FULL SCHEMA;" \
    > "${SCHEMA_FILE}"
gzip "${SCHEMA_FILE}"

ln -sfn "${SCHEMA_FILE}.gz" "${COHESITY_PICKUP_DIR}/schema_latest.cql.gz"
log "INFO" "Schema exported (symlink updated: schema_latest.cql.gz)"

find "${COHESITY_PICKUP_DIR}" -name "schema_*.cql.gz" \
    -mtime "+${RETENTION_DAYS}" -delete
log "INFO" "Purged schema files older than ${RETENTION_DAYS} days"
