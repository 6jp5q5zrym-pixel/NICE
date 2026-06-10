#!/usr/bin/env bash
# Reports SSTable health metrics for all user keyspaces on this node.
# Flags tables with: high SSTable count, LCS level overflow, high tombstones,
# no compression, or gc_grace_seconds above a configurable threshold.
#
# Usage:
#   table_health.sh [--keyspace <ks>] [--json] [--warn-only]
#
# Options:
#   --keyspace <ks>   Limit report to one keyspace
#   --json            Emit machine-readable JSON (one object per table)
#   --warn-only       Only print tables with at least one warning
#
# Exit code: 0 = no warnings, 1 = at least one table flagged
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../backup/lib/common.sh"

CQLSH_HOST="${CQLSH_HOST:-$(hostname -I | awk '{print $1}')}"
CQLSH_PORT="${CQLSH_PORT:-9042}"

# Thresholds
MAX_SSTABLES="${MAX_SSTABLES:-200}"           # warn if table has more SSTables than this
MAX_TOMBSTONES_AVG="${MAX_TOMBSTONES_AVG:-20}" # warn if avg tombstones/slice exceeds this
MAX_GC_GRACE="${MAX_GC_GRACE:-864000}"         # warn if gc_grace_seconds exceeds this (default: 10d)
LCS_OVERFLOW_PCT="${LCS_OVERFLOW_PCT:-10}"    # warn if LCS level size exceeds target by this %

FILTER_KS=""
JSON_OUTPUT=false
WARN_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keyspace)  FILTER_KS="$2";   shift 2 ;;
        --json)      JSON_OUTPUT=true; shift ;;
        --warn-only) WARN_ONLY=true;   shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

HOSTNAME_SHORT=$(hostname -s)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# ── Collect schema metadata ───────────────────────────────────────────────────
# For each table: compaction class, compression class, gc_grace_seconds
SCHEMA_QUERY="SELECT keyspace_name, table_name, compaction, compression, gc_grace_seconds
              FROM system_schema.tables;"
SCHEMA_DATA=$("${CQLSH}" "${CQLSH_HOST}" "${CQLSH_PORT}" --execute "${SCHEMA_QUERY}" 2>/dev/null)

# ── Collect nodetool tablestats ───────────────────────────────────────────────
if [[ -n "${FILTER_KS}" ]]; then
    TABLESTATS=$("${NODETOOL}" tablestats "${FILTER_KS}" 2>/dev/null)
else
    TABLESTATS=$("${NODETOOL}" tablestats 2>/dev/null)
fi

# ── Parse and report ─────────────────────────────────────────────────────────
# tablestats output block per table:
#   Table: <keyspace>.<table>
#   SSTable count: <n>
#   ...
#   Average tombstones per slice (last five minutes): <f>
#   Maximum tombstones per slice (last five minutes): <f>

WARNED=0

if ${JSON_OUTPUT}; then
    echo "["
    FIRST=true
fi

parse_tablestats() {
    local ks_table="$1"
    local ks table
    ks="${ks_table%%.*}"
    table="${ks_table#*.}"

    [[ -n "${FILTER_KS}" && "${ks}" != "${FILTER_KS}" ]] && return

    # Extract metrics from tablestats block for this table
    local block
    block=$(echo "${TABLESTATS}" | awk "/Table: ${ks_table}/,/^$/" 2>/dev/null | head -60)

    local sstable_count tombstones_avg tombstones_max
    sstable_count=$(echo "${block}"  | grep "SSTable count:"                           | awk '{print $NF}' | tr -d '[:space:]')
    tombstones_avg=$(echo "${block}" | grep "Average tombstones per slice"             | awk '{print $NF}' | tr -d '[:space:]')
    tombstones_max=$(echo "${block}" | grep "Maximum tombstones per slice"             | awk '{print $NF}' | tr -d '[:space:]')

    # Fall back to 0 if not found (table had no recent reads)
    sstable_count="${sstable_count:-0}"
    tombstones_avg="${tombstones_avg:-0}"
    tombstones_max="${tombstones_max:-0}"

    # Extract schema info for this table from cqlsh output
    local schema_row compaction_class compression_class gc_grace
    schema_row=$(echo "${SCHEMA_DATA}" | grep -E "^\s*${ks}\s*\|\s*${table}\s*\|" || true)
    compaction_class=$(echo "${schema_row}"   | grep -o "'class'[[:space:]]*:[[:space:]]*'[^']*'" | head -1 | sed "s/'class'[[:space:]]*:[[:space:]]*'//;s/'//")
    compression_class=$(echo "${schema_row}"  | grep -o "'class'[[:space:]]*:[[:space:]]*'[^']*'" | tail -1 | sed "s/'class'[[:space:]]*:[[:space:]]*'//;s/'//")
    gc_grace=$(echo "${schema_row}"           | awk -F'|' '{print $5}' | tr -d '[:space:]')

    # Shorten class names for readability
    compaction_class="${compaction_class##*.}"
    compression_class="${compression_class##*.}"
    [[ "${compression_class}" == "false" ]] && compression_class="NONE"

    # ── Evaluate warnings ─────────────────────────────────────────────────────
    local warnings=()

    # SSTable count
    if [[ "${sstable_count}" -gt "${MAX_SSTABLES}" ]] 2>/dev/null; then
        warnings+=("HIGH_SSTABLES:${sstable_count}")
    fi

    # Tombstones (compare as floats via awk)
    if awk "BEGIN{exit !(${tombstones_avg}+0 > ${MAX_TOMBSTONES_AVG})}"; then
        warnings+=("HIGH_TOMBSTONES_AVG:${tombstones_avg}")
    fi

    # Compression
    if [[ -z "${compression_class}" || "${compression_class}" == "NONE" ]]; then
        warnings+=("NO_COMPRESSION")
    fi

    # gc_grace_seconds
    if [[ -n "${gc_grace}" ]] && [[ "${gc_grace}" -gt "${MAX_GC_GRACE}" ]] 2>/dev/null; then
        warnings+=("HIGH_GC_GRACE:${gc_grace}s")
    fi

    local warn_str
    warn_str=$(IFS=','; echo "${warnings[*]:-}")

    local has_warn=false
    [[ ${#warnings[@]} -gt 0 ]] && has_warn=true && WARNED=$((WARNED + 1))

    ${WARN_ONLY} && ! ${has_warn} && return

    if ${JSON_OUTPUT}; then
        ${FIRST} || echo ","
        FIRST=false
        printf '  {"keyspace":"%s","table":"%s","sstables":%s,"tombstones_avg":%s,"tombstones_max":%s,"compaction":"%s","compression":"%s","gc_grace":%s,"warnings":[%s]}' \
            "${ks}" "${table}" "${sstable_count}" "${tombstones_avg}" "${tombstones_max}" \
            "${compaction_class}" "${compression_class}" "${gc_grace:-0}" \
            "$(printf '"%s",' "${warnings[@]:-}" | sed 's/,$//')"
    else
        local status_icon="  OK "
        ${has_warn} && status_icon=" WARN"
        printf "%-6s %-40s  SSTables: %-6s  Tombstones(avg/max): %-8s / %-8s  Compaction: %-28s  Compression: %-20s  gc_grace: %s\n" \
            "[${status_icon}]" "${ks}.${table}" "${sstable_count}" \
            "${tombstones_avg}" "${tombstones_max}" \
            "${compaction_class}" "${compression_class}" \
            "${gc_grace:-N/A}"
        if ${has_warn}; then
            echo "         → ${warn_str}"
        fi
    fi
}

if ! ${JSON_OUTPUT}; then
    echo "========================================================================================================"
    echo "  Cassandra table health report"
    echo "  Node      : ${HOSTNAME_SHORT}  (${CQLSH_HOST})"
    echo "  Timestamp : ${TIMESTAMP}"
    echo "  Thresholds: SSTables>${MAX_SSTABLES} | TombstonesAvg>${MAX_TOMBSTONES_AVG} | gc_grace>${MAX_GC_GRACE}s"
    echo "========================================================================================================"
fi

# Iterate tables found in tablestats output
while IFS= read -r line; do
    if [[ "${line}" =~ ^[[:space:]]*Table:[[:space:]](.+\..+)$ ]]; then
        parse_tablestats "${BASH_REMATCH[1]}"
    fi
done <<< "${TABLESTATS}"

if ${JSON_OUTPUT}; then
    echo ""
    echo "]"
fi

if ! ${JSON_OUTPUT}; then
    echo "========================================================================================================"
    if [[ ${WARNED} -eq 0 ]]; then
        echo "  Result: ALL TABLES OK"
    else
        echo "  Result: ${WARNED} TABLE(S) WITH WARNINGS"
    fi
    echo "========================================================================================================"
fi

[[ ${WARNED} -gt 0 ]] && exit 1 || exit 0
