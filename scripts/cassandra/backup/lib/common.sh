#!/usr/bin/env bash
# Shared helpers for all Cassandra backup/restore scripts.

LOG_DIR="${LOG_DIR:-/var/log/cassandra/backup}"
mkdir -p "${LOG_DIR}"

log() {
    local level="$1"
    local msg="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${msg}"
}

# Verifies that nodetool can reach the local Cassandra node.
check_cassandra_alive() {
    if ! nodetool status &>/dev/null; then
        log "ERROR" "Cassandra node is not reachable via nodetool. Aborting."
        exit 1
    fi
}

# Returns the list of non-system keyspaces.
get_user_keyspaces() {
    local host="${1:-127.0.0.1}"
    local port="${2:-9042}"
    cqlsh "${host}" "${port}" --execute "SELECT keyspace_name FROM system_schema.keyspaces;" \
        | grep -Ev "^\s*(keyspace_name|---|system|system_|dse_|solr_admin|\()" \
        | awk 'NF {print $1}'
}
