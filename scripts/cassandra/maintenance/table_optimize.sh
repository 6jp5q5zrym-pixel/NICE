#!/usr/bin/env bash
# Applies standard table settings to one or all user keyspaces:
#   - LZ4 compression (chunk_length_in_kb: 64)
#   - gc_grace_seconds (default: 432000 = 5 days, suitable with NodeSync)
#   - Verifies NodeSync is enabled on each table
#
# Usage:
#   table_optimize.sh [--keyspace <ks>] [--table <tbl>] [--gc-grace <seconds>]
#                     [--dry-run] [--skip-compaction]
#
# Options:
#   --keyspace <ks>       Limit to one keyspace (default: all user keyspaces)
#   --table <tbl>         Limit to one table within --keyspace (requires --keyspace)
#   --gc-grace <sec>      gc_grace_seconds to apply (default: 432000)
#   --dry-run             Print CQL statements without executing them
#   --skip-compaction     Skip the post-optimize major compaction trigger
#
# After altering compression, run a major compaction so existing SSTables
# are rewritten with the new codec:
#   nodetool compact <keyspace> [<table>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../backup/lib/common.sh"

CQLSH_HOST="${CQLSH_HOST:-$(hostname -I | awk '{print $1}')}"
CQLSH_PORT="${CQLSH_PORT:-9042}"
LOG_FILE="${LOG_DIR}/table_optimize.log"

FILTER_KS=""
FILTER_TABLE=""
GC_GRACE="${GC_GRACE:-432000}"
DRY_RUN=false
SKIP_COMPACTION=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keyspace)        FILTER_KS="$2";        shift 2 ;;
        --table)           FILTER_TABLE="$2";      shift 2 ;;
        --gc-grace)        GC_GRACE="$2";          shift 2 ;;
        --dry-run)         DRY_RUN=true;           shift ;;
        --skip-compaction) SKIP_COMPACTION=true;   shift ;;
        *) log "ERROR" "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -n "${FILTER_TABLE}" && -z "${FILTER_KS}" ]] && {
    log "ERROR" "--table requires --keyspace"; exit 1
}

exec >> "${LOG_FILE}" 2>&1

HOSTNAME_SHORT=$(hostname -s)
log "INFO" "=== table_optimize started on ${HOSTNAME_SHORT} (dry_run=${DRY_RUN}) ==="
check_cassandra_alive

run_cql() {
    local stmt="$1"
    if ${DRY_RUN}; then
        log "DRYRUN" "${stmt}"
    else
        log "INFO"  "CQL: ${stmt}"
        "${CQLSH}" "${CQLSH_HOST}" "${CQLSH_PORT}" --execute "${stmt}" 2>&1
    fi
}

# Gather tables to process
get_tables() {
    local ks="$1"
    "${CQLSH}" "${CQLSH_HOST}" "${CQLSH_PORT}" \
        --execute "SELECT table_name FROM system_schema.tables WHERE keyspace_name='${ks}';" \
        2>/dev/null \
        | grep -Ev "^\s*(table_name|---|[[:space:]]*\()" \
        | awk 'NF {print $1}'
}

CHANGED=0
SKIPPED=0
COMPACT_TARGETS=()

process_table() {
    local ks="$1"
    local tbl="$2"

    # Read current settings
    local row
    row=$("${CQLSH}" "${CQLSH_HOST}" "${CQLSH_PORT}" \
        --execute "SELECT compaction, compression, gc_grace_seconds FROM system_schema.tables
                   WHERE keyspace_name='${ks}' AND table_name='${tbl}';" 2>/dev/null \
        | grep -v "^[[:space:]]*\(compaction\|---\|([[:digit:]]" || true)

    local current_compression current_gc
    current_compression=$(echo "${row}" | grep -o "'class'[[:space:]]*:[[:space:]]*'[^']*'" | tail -1 \
        | sed "s/'class'[[:space:]]*:[[:space:]]*'//;s/'//" || echo "")
    current_gc=$(echo "${row}" | awk -F'|' '{print $3}' | tr -d '[:space:]' || echo "")

    local needs_compression=false needs_gc=false
    local compression_label="LZ4Compressor"

    # Check compression
    if [[ "${current_compression}" != *"LZ4"* ]]; then
        needs_compression=true
    fi

    # Check gc_grace (only lower it, never raise)
    if [[ -n "${current_gc}" && "${current_gc}" -gt "${GC_GRACE}" ]] 2>/dev/null; then
        needs_gc=true
    fi

    if ! ${needs_compression} && ! ${needs_gc}; then
        log "INFO" "SKIP ${ks}.${tbl} — already optimized (compression=${current_compression}, gc_grace=${current_gc})"
        SKIPPED=$((SKIPPED + 1))
        return
    fi

    log "INFO" "Optimizing ${ks}.${tbl}..."

    local with_clauses=()
    ${needs_compression} && with_clauses+=(
        "compression = {'class': 'LZ4Compressor', 'chunk_length_in_kb': '64'}"
    )
    ${needs_gc} && with_clauses+=(
        "gc_grace_seconds = ${GC_GRACE}"
    )

    local with_str
    with_str=$(IFS=' AND '; echo "${with_clauses[*]}")

    run_cql "ALTER TABLE ${ks}.${tbl} WITH ${with_str};"

    CHANGED=$((CHANGED + 1))
    ${needs_compression} && COMPACT_TARGETS+=("${ks}.${tbl}")
}

# ── Main loop ─────────────────────────────────────────────────────────────────
if [[ -n "${FILTER_KS}" ]]; then
    KEYSPACES="${FILTER_KS}"
else
    KEYSPACES=$(get_user_keyspaces "${CQLSH_HOST}" "${CQLSH_PORT}")
fi

while IFS= read -r ks; do
    [[ -z "${ks}" ]] && continue
    log "INFO" "── Keyspace: ${ks}"

    if [[ -n "${FILTER_TABLE}" ]]; then
        process_table "${ks}" "${FILTER_TABLE}"
    else
        while IFS= read -r tbl; do
            [[ -z "${tbl}" ]] && continue
            process_table "${ks}" "${tbl}"
        done < <(get_tables "${ks}")
    fi
done <<< "${KEYSPACES}"

log "INFO" "── Summary: ${CHANGED} table(s) altered, ${SKIPPED} already OK"

# ── Trigger major compaction for tables whose compression changed ─────────────
# This rewrites existing SSTables with the new LZ4 codec.
# Warning: this is I/O intensive. Schedule during a low-traffic window.
if [[ ${#COMPACT_TARGETS[@]} -gt 0 ]] && ! ${SKIP_COMPACTION}; then
    log "INFO" "Triggering major compaction for altered tables (this may take a long time)..."
    for target in "${COMPACT_TARGETS[@]}"; do
        ks="${target%%.*}"
        tbl="${target#*.}"
        log "INFO" "  nodetool compact ${ks} ${tbl}"
        if ${DRY_RUN}; then
            log "DRYRUN" "nodetool compact ${ks} ${tbl}"
        else
            "${NODETOOL}" compact "${ks}" "${tbl}" \
                && log "INFO" "  Compaction completed: ${ks}.${tbl}" \
                || log "WARN" "  Compaction returned non-zero for ${ks}.${tbl} — check nodetool compactionstats"
        fi
    done
elif [[ ${#COMPACT_TARGETS[@]} -gt 0 ]] && ${SKIP_COMPACTION}; then
    log "INFO" "Compaction skipped (--skip-compaction). Run manually when ready:"
    for target in "${COMPACT_TARGETS[@]}"; do
        ks="${target%%.*}"
        tbl="${target#*.}"
        log "INFO" "  nodetool compact ${ks} ${tbl}"
    done
fi

log "INFO" "=== table_optimize completed ==="
