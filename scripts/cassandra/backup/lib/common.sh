#!/usr/bin/env bash
# Shared helpers for all Cassandra backup/restore scripts.

DSE_HOME="${DSE_HOME:-/opt/datastax/dse-6.8.36}"
CQLSH="${DSE_HOME}/bin/cqlsh"
NODETOOL="${DSE_HOME}/bin/nodetool"

LOG_DIR="${LOG_DIR:-/logs/cassandra/backup}"
mkdir -p "${LOG_DIR}"

log() {
    local level="$1"
    local msg="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${msg}"
}

# Verifies that nodetool can reach the local Cassandra node.
check_cassandra_alive() {
    if ! "${NODETOOL}" status &>/dev/null; then
        log "ERROR" "Cassandra node is not reachable via nodetool. Aborting."
        exit 1
    fi
}

# Verifies that the Cohesity share is mounted at the given path.
# Prevents scripts from writing to local disk if the share is down.
check_cohesity_mounted() {
    local mount_path="${1}"
    if ! mountpoint -q "${mount_path}"; then
        log "ERROR" "Cohesity share not mounted at ${mount_path}. Aborting to prevent writing to local disk."
        log "ERROR" "Check mount: sudo mount ${mount_path}"
        exit 1
    fi
}

# Returns the list of non-system keyspaces.
get_user_keyspaces() {
    local host="${1:-127.0.0.1}"
    local port="${2:-9042}"
    "${CQLSH}" "${host}" "${port}" --execute "SELECT keyspace_name FROM system_schema.keyspaces;" \
        | grep -Ev "^\s*(keyspace_name|---|system|system_|dse_|solr_admin|\()" \
        | awk 'NF {print $1}'
}
