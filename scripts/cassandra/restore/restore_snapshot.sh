#!/usr/bin/env bash
# Restores a Cassandra cluster from a daily snapshot and optionally replays
# commit logs up to a target timestamp (point-in-time recovery).
#
# Usage:
#   restore_snapshot.sh --snapshot <path> [--commitlog-dir <path>] [--target-time <ISO8601>]
#
# Examples:
#   # Restore latest snapshot only
#   restore_snapshot.sh --snapshot /var/lib/cassandra/snapshots_export/daily_20260101_010000
#
#   # Restore snapshot + replay commit logs up to a specific time (logical error recovery)
#   restore_snapshot.sh \
#     --snapshot /var/lib/cassandra/snapshots_export/daily_20260101_010000 \
#     --commitlog-dir /var/lib/cassandra/commitlog_staging \
#     --target-time "2026-01-01T09:30:00"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../backup/lib/common.sh"

CQLSH_HOST="${CQLSH_HOST:-127.0.0.1}"
CQLSH_PORT="${CQLSH_PORT:-9042}"
DATA_DIR="${DATA_DIR:-/var/lib/cassandra/data}"
LOG_FILE="${LOG_DIR}/restore.log"

SNAPSHOT_PATH=""
COMMITLOG_DIR=""
TARGET_TIME=""

usage() {
    grep '^# ' "$0" | sed 's/^# //'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --snapshot)     SNAPSHOT_PATH="$2"; shift 2 ;;
        --commitlog-dir) COMMITLOG_DIR="$2"; shift 2 ;;
        --target-time)  TARGET_TIME="$2";  shift 2 ;;
        -h|--help)      usage ;;
        *) log "ERROR" "Unknown argument: $1"; usage ;;
    esac
done

[[ -z "${SNAPSHOT_PATH}" ]] && { log "ERROR" "--snapshot is required"; usage; }
[[ ! -d "${SNAPSHOT_PATH}" ]] && { log "ERROR" "Snapshot directory not found: ${SNAPSHOT_PATH}"; exit 1; }

exec >> "${LOG_FILE}" 2>&1
log "INFO" "=== Restore started ==="
log "INFO" "Snapshot : ${SNAPSHOT_PATH}"
log "INFO" "Commit logs: ${COMMITLOG_DIR:-none}"
log "INFO" "Target time: ${TARGET_TIME:-latest}"

# ── PRE-FLIGHT ────────────────────────────────────────────────────────────────

# 1 – Stop DSE/Cassandra service
log "INFO" "Stopping Cassandra service..."
systemctl stop dse || systemctl stop cassandra

# 2 – Restore schema first so tables exist before data is loaded
if [[ -f "${SNAPSHOT_PATH}/../schema/schema_latest.cql.gz" ]]; then
    SCHEMA_FILE="${SNAPSHOT_PATH}/../schema/schema_latest.cql.gz"
elif [[ -n "$(find "$(dirname "${SNAPSHOT_PATH}")" -name 'schema_*.cql.gz' -maxdepth 2 2>/dev/null | head -1)" ]]; then
    SCHEMA_FILE=$(find "$(dirname "${SNAPSHOT_PATH}")" -name 'schema_*.cql.gz' -maxdepth 2 | sort | tail -1)
else
    log "WARN" "No schema file found alongside snapshot – skipping schema restore."
    SCHEMA_FILE=""
fi

# 3 – Clear existing data directory (destructive – ensure snapshot is intact first)
log "INFO" "Clearing existing data directory: ${DATA_DIR}"
find "${DATA_DIR}" -mindepth 3 -name "*.db" -delete
find "${DATA_DIR}" -mindepth 3 -name "*.idx" -delete

# ── SCHEMA RESTORE ────────────────────────────────────────────────────────────

if [[ -n "${SCHEMA_FILE}" ]]; then
    log "INFO" "Restoring schema from ${SCHEMA_FILE}..."
    systemctl start dse || systemctl start cassandra
    sleep 30  # wait for Cassandra to be ready
    zcat "${SCHEMA_FILE}" | cqlsh "${CQLSH_HOST}" "${CQLSH_PORT}"
    log "INFO" "Schema restored"
    systemctl stop dse || systemctl stop cassandra
fi

# ── DATA RESTORE ──────────────────────────────────────────────────────────────

log "INFO" "Copying snapshot data → ${DATA_DIR}..."
while IFS= read -r -d '' keyspace_dir; do
    keyspace=$(basename "${keyspace_dir}")
    while IFS= read -r -d '' table_dir; do
        table=$(basename "${table_dir}")
        # Find the matching SSTable directory (Cassandra appends a UUID suffix)
        dest_dir=$(find "${DATA_DIR}/${keyspace}" -maxdepth 1 -type d -name "${table}-*" 2>/dev/null | head -1)
        if [[ -z "${dest_dir}" ]]; then
            log "WARN" "No destination directory found for ${keyspace}/${table} – skipping"
            continue
        fi
        cp -a "${table_dir}/." "${dest_dir}/"
        log "INFO" "  Restored ${keyspace}/${table}"
    done < <(find "${keyspace_dir}" -maxdepth 1 -mindepth 1 -type d -print0)
done < <(find "${SNAPSHOT_PATH}" -maxdepth 1 -mindepth 1 -type d -print0)

# Fix ownership
chown -R cassandra:cassandra "${DATA_DIR}" 2>/dev/null || true

# ── COMMIT LOG REPLAY (point-in-time recovery) ────────────────────────────────

if [[ -n "${COMMITLOG_DIR}" ]]; then
    REPLAY_DIR="/var/lib/cassandra/commitlog_replay"
    mkdir -p "${REPLAY_DIR}"

    log "INFO" "Staging commit log files for replay from ${COMMITLOG_DIR}..."
    # Collect all commit log segments from hourly staging dirs
    find "${COMMITLOG_DIR}" -name "CommitLog-*.log" | sort | while read -r clog; do
        cp "${clog}" "${REPLAY_DIR}/"
    done

    # Configure Cassandra to replay commit logs from REPLAY_DIR on startup
    CASSANDRA_YAML="${CASSANDRA_YAML:-/etc/dse/cassandra/cassandra.yaml}"
    if grep -q "^commitlog_directory:" "${CASSANDRA_YAML}"; then
        sed -i "s|^commitlog_directory:.*|commitlog_directory: ${REPLAY_DIR}|" "${CASSANDRA_YAML}"
    fi

    if [[ -n "${TARGET_TIME}" ]]; then
        log "INFO" "Point-in-time recovery target: ${TARGET_TIME}"
        log "INFO" "Set commitlog_archiving.properties to stop replay at ${TARGET_TIME}"
        # Cassandra's commitlog archiving supports RESTORE_POINT_IN_TIME
        ARCHIVE_PROPS="/etc/dse/cassandra/commitlog_archiving.properties"
        cat > "${ARCHIVE_PROPS}" <<EOF
restore_directories=${REPLAY_DIR}
restore_point_in_time=${TARGET_TIME}
EOF
        log "INFO" "commitlog_archiving.properties written"
    fi
fi

# ── START SERVICE ─────────────────────────────────────────────────────────────

log "INFO" "Starting Cassandra service..."
systemctl start dse || systemctl start cassandra

log "INFO" "Waiting for node to become available..."
until nodetool status &>/dev/null; do sleep 5; done
log "INFO" "Node is UP"

# Run nodetool repair after restore to ensure consistency across replicas
log "INFO" "Running nodetool repair to synchronize replicas..."
nodetool repair --full &

log "INFO" "=== Restore completed. Monitor repair progress with: nodetool compactionstats ==="
