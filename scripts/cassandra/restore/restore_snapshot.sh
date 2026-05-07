#!/usr/bin/env bash
# Restores a Cassandra node from a backup package produced by daily_snapshot.sh.
# Optionally replays commit log packages for point-in-time recovery (PITR).
#
# Usage:
#   restore_snapshot.sh --package <backup.tar.gz> [--commitlogs <dir|tar.gz>...] [--target-time <ISO8601>]
#
# Examples:
#   # Restore latest daily snapshot only
#   restore_snapshot.sh \
#     --package /datos/backup/cohesity_pickup/daily/cassandra_backup_node1_20260428_010000.tar.gz
#
#   # Restore + replay commit logs up to a specific time (logical error / accidental delete)
#   restore_snapshot.sh \
#     --package /datos/backup/cohesity_pickup/daily/cassandra_backup_node1_20260428_010000.tar.gz \
#     --commitlogs /datos/backup/cohesity_pickup/commitlogs \
#     --target-time "2026-04-28T09:30:00"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../backup/lib/common.sh"

CQLSH_HOST="${CQLSH_HOST:-$(hostname -I | awk '{print $1}')}"
CQLSH_PORT="${CQLSH_PORT:-9042}"
DATA_DIR="${DATA_DIR:-/datos/dse-data}"
CASSANDRA_YAML="${CASSANDRA_YAML:-/etc/dse/cassandra/cassandra.yaml}"
EXTRACT_DIR="${EXTRACT_DIR:-/datos/restore_staging}"
LOG_FILE="${LOG_DIR}/restore.log"

# When run as root (sudo), cqlsh looks for cqlshrc in root's HOME.
# Set HOME to the cassandra OS user's home so cqlsh finds its credentials.
export HOME="$(getent passwd cassandra | cut -d: -f6)"

PACKAGE_FILE=""
COMMITLOGS_SRC=""
TARGET_TIME=""

usage() {
    grep '^# ' "$0" | sed 's/^# //'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --package)      PACKAGE_FILE="$2";    shift 2 ;;
        --commitlogs)   COMMITLOGS_SRC="$2";  shift 2 ;;
        --target-time)  TARGET_TIME="$2";     shift 2 ;;
        -h|--help)      usage ;;
        *) log "ERROR" "Unknown argument: $1"; usage ;;
    esac
done

[[ -z "${PACKAGE_FILE}" ]]       && { log "ERROR" "--package is required"; usage; }
[[ ! -f "${PACKAGE_FILE}" ]]     && { log "ERROR" "Package not found: ${PACKAGE_FILE}"; exit 1; }

exec >> "${LOG_FILE}" 2>&1
log "INFO" "======================================================"
log "INFO" "=== Restore started"
log "INFO" "Package      : ${PACKAGE_FILE}"
log "INFO" "Commit logs  : ${COMMITLOGS_SRC:-none (snapshot-only restore)}"
log "INFO" "Target time  : ${TARGET_TIME:-latest (no PITR)}"
log "INFO" "======================================================"

# ── 1. EXTRACT BACKUP PACKAGE ────────────────────────────────────────────────
rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"
log "INFO" "Extracting package..."
tar -xzf "${PACKAGE_FILE}" -C "${EXTRACT_DIR}"

PACKAGE_DIR=$(find "${EXTRACT_DIR}" -maxdepth 1 -mindepth 1 -type d | head -1)
SCHEMA_FILE="${PACKAGE_DIR}/schema/schema.cql"
DATA_SNAPSHOT_DIR="${PACKAGE_DIR}/data"

log "INFO" "Package extracted to: ${PACKAGE_DIR}"
cat "${PACKAGE_DIR}/manifest.json" | grep -E '"(backup_type|timestamp|dse_version|keyspaces)"' || true

# ── 2. STOP CASSANDRA ────────────────────────────────────────────────────────
log "INFO" "Stopping Cassandra service..."
systemctl stop dse 2>/dev/null || systemctl stop cassandra

# ── 3. CLEAR EXISTING DATA ───────────────────────────────────────────────────
# Removes only SSTable files, preserving directory structure.
log "INFO" "Clearing existing SSTable files in ${DATA_DIR}..."
find "${DATA_DIR}" -mindepth 4 \
    \( -name "*.db" -o -name "*.idx" -o -name "*.sha1" -o -name "*.crc32" \) \
    -delete

# ── 4. RESTORE SCHEMA ────────────────────────────────────────────────────────
if [[ -f "${SCHEMA_FILE}" ]]; then
    log "INFO" "Restoring CQL schema..."
    systemctl start dse 2>/dev/null || systemctl start cassandra
    log "INFO" "Waiting for Cassandra to accept connections..."
    until "${CQLSH}" "${CQLSH_HOST}" "${CQLSH_PORT}" --execute "DESCRIBE KEYSPACES;" &>/dev/null; do
        sleep 5
    done
    "${CQLSH}" "${CQLSH_HOST}" "${CQLSH_PORT}" --file "${SCHEMA_FILE}" 2>&1 || true
    log "INFO" "Schema restored"
    systemctl stop dse 2>/dev/null || systemctl stop cassandra
else
    log "WARN" "No schema file found in package – skipping schema restore"
fi

# ── 5. RESTORE SSTABLE DATA ──────────────────────────────────────────────────
log "INFO" "Restoring SSTable data..."
TABLE_COUNT=0
while IFS= read -r -d '' keyspace_dir; do
    keyspace=$(basename "${keyspace_dir}")
    while IFS= read -r -d '' table_dir; do
        table_uuid=$(basename "${table_dir}")
        dest_dir="${DATA_DIR}/${keyspace}/${table_uuid}"
        mkdir -p "${dest_dir}"
        cp -a "${table_dir}/." "${dest_dir}/"
        TABLE_COUNT=$((TABLE_COUNT + 1))
    done < <(find "${keyspace_dir}" -maxdepth 1 -mindepth 1 -type d -print0)
done < <(find "${DATA_SNAPSHOT_DIR}" -maxdepth 1 -mindepth 1 -type d -print0)

chown -R cassandra:cassandra "${DATA_DIR}" 2>/dev/null || true
log "INFO" "Restored ${TABLE_COUNT} table(s)"

# ── 6. COMMIT LOG REPLAY (PITR) ──────────────────────────────────────────────
if [[ -n "${COMMITLOGS_SRC}" ]]; then
    REPLAY_DIR="/var/lib/cassandra/commitlog_replay"
    rm -rf "${REPLAY_DIR}"
    mkdir -p "${REPLAY_DIR}"

    log "INFO" "Staging commit log segments from: ${COMMITLOGS_SRC}"

    # Accept either a directory of tar.gz packages or a directory of raw .log files
    if find "${COMMITLOGS_SRC}" -name "cassandra_commitlog_*.tar.gz" -maxdepth 2 | grep -q .; then
        log "INFO" "Extracting commit log packages..."
        CL_EXTRACT="${EXTRACT_DIR}/commitlogs"
        mkdir -p "${CL_EXTRACT}"
        find "${COMMITLOGS_SRC}" -name "cassandra_commitlog_*.tar.gz" | sort | while read -r pkg; do
            tar -xzf "${pkg}" -C "${CL_EXTRACT}"
        done
        find "${CL_EXTRACT}" -name "CommitLog-*.log" | sort | xargs -I{} cp {} "${REPLAY_DIR}/"
    else
        find "${COMMITLOGS_SRC}" -name "CommitLog-*.log" | sort | xargs -I{} cp {} "${REPLAY_DIR}/"
    fi

    SEGMENTS=$(find "${REPLAY_DIR}" -name "CommitLog-*.log" | wc -l)
    log "INFO" "Staged ${SEGMENTS} commit log segment(s) for replay"

    # Point cassandra.yaml at the replay directory
    sed -i "s|^commitlog_directory:.*|commitlog_directory: ${REPLAY_DIR}|" "${CASSANDRA_YAML}"

    if [[ -n "${TARGET_TIME}" ]]; then
        log "INFO" "PITR target: ${TARGET_TIME}"
        ARCHIVE_PROPS="$(dirname "${CASSANDRA_YAML}")/commitlog_archiving.properties"
        cat > "${ARCHIVE_PROPS}" <<EOF
restore_directories=${REPLAY_DIR}
restore_point_in_time=${TARGET_TIME}
EOF
        log "INFO" "commitlog_archiving.properties written: ${ARCHIVE_PROPS}"
    fi
fi

# ── 7. START CASSANDRA & VERIFY ──────────────────────────────────────────────
log "INFO" "Starting Cassandra service..."
systemctl start dse 2>/dev/null || systemctl start cassandra

log "INFO" "Waiting for node to become available..."
until "${NODETOOL}" status &>/dev/null; do sleep 5; done
log "INFO" "Node is UP – running status:"
"${NODETOOL}" status | tail -n +4

# Trigger repair to sync this node with the rest of the cluster
log "INFO" "Launching background repair (monitor with: "${NODETOOL}" compactionstats)..."
nohup "${NODETOOL}" repair --full >> "${LOG_DIR}/repair_after_restore.log" 2>&1 &

log "INFO" "=== Restore completed successfully ==="
