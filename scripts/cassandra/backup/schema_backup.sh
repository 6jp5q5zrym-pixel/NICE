#!/usr/bin/env bash
# Exports the full CQL schema (keyspaces, tables, indexes, primary keys).
# Must run before daily_snapshot.sh so the schema file is included in the snapshot export.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

CQLSH_HOST="${CQLSH_HOST:-127.0.0.1}"
CQLSH_PORT="${CQLSH_PORT:-9042}"
SCHEMA_DIR="${SCHEMA_DIR:-/var/lib/cassandra/schema_backups}"
LOG_FILE="${LOG_DIR:-/var/log/cassandra/backup}/schema_backup.log"
RETENTION_DAYS="${RETENTION_DAYS:-30}"

mkdir -p "${SCHEMA_DIR}"
exec >> "${LOG_FILE}" 2>&1

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
SCHEMA_FILE="${SCHEMA_DIR}/schema_${TIMESTAMP}.cql"

log "INFO" "Starting schema backup → ${SCHEMA_FILE}"

cqlsh "${CQLSH_HOST}" "${CQLSH_PORT}" \
    --execute "DESCRIBE FULL SCHEMA;" \
    > "${SCHEMA_FILE}"

gzip "${SCHEMA_FILE}"
log "INFO" "Schema exported and compressed: ${SCHEMA_FILE}.gz"

# Symlink to latest for easy reference
ln -sfn "${SCHEMA_FILE}.gz" "${SCHEMA_DIR}/schema_latest.cql.gz"

# Purge files older than retention period
find "${SCHEMA_DIR}" -name "schema_*.cql.gz" -mtime "+${RETENTION_DAYS}" -delete
log "INFO" "Purged schema files older than ${RETENTION_DAYS} days"

log "INFO" "Schema backup completed successfully"
