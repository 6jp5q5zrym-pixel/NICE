#!/usr/bin/env bash
# Standalone schema export – produces schema_<HOSTNAME>_<TIMESTAMP>.cql.gz
# in COHESITY_PICKUP_DIR/schema/.
# The schema is also embedded inside daily_snapshot.sh packages, so this
# script is only needed for independent schema-only restores or audits.
# Schedule: daily at 00:50 (10 min before daily_snapshot.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

CQLSH_HOST="${CQLSH_HOST:-$(hostname -I | awk '{print $1}')}"
CQLSH_PORT="${CQLSH_PORT:-9042}"
COHESITY_PICKUP_DIR="${COHESITY_PICKUP_DIR:-/datos/backup/cohesity_pickup/schema}"
LOG_FILE="${LOG_DIR}/schema_backup.log"
RETENTION_MINUTES="${RETENTION_MINUTES:-2880}"

exec >> "${LOG_FILE}" 2>&1
mkdir -p "${COHESITY_PICKUP_DIR}"

HOSTNAME_SHORT=$(hostname -s)
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
SCHEMA_FILE="${COHESITY_PICKUP_DIR}/schema_${HOSTNAME_SHORT}_${TIMESTAMP}.cql"

log "INFO" "Exporting CQL schema (user keyspaces only) → ${SCHEMA_FILE}.gz"
: > "${SCHEMA_FILE}"
while IFS= read -r ks; do
    "${CQLSH}" "${CQLSH_HOST}" "${CQLSH_PORT}" \
        --execute "DESCRIBE KEYSPACE ${ks};" \
        >> "${SCHEMA_FILE}"
done < <(get_user_keyspaces "${CQLSH_HOST}" "${CQLSH_PORT}")
gzip "${SCHEMA_FILE}"

ln -sfn "${SCHEMA_FILE}.gz" "${COHESITY_PICKUP_DIR}/schema_latest.cql.gz"
log "INFO" "Schema exported (symlink updated: schema_latest.cql.gz)"

find "${COHESITY_PICKUP_DIR}" -name "schema_*.cql.gz" \
    -mmin "+${RETENTION_MINUTES}" -delete
log "INFO" "Purged schema files older than ${RETENTION_MINUTES} minutes ($(( RETENTION_MINUTES / 60 ))h)"
