#!/usr/bin/env bash
# Polls nodetool compactionstats every N seconds and prints progress.
# Use this to monitor a running major compaction.
#
# Usage:
#   compaction_watch.sh [--interval <seconds>] [--keyspace <ks>] [--table <tbl>]
#
# Options:
#   --interval <sec>   Refresh interval (default: 15)
#   --keyspace <ks>    Filter output to keyspace
#   --table <tbl>      Filter output to table (requires --keyspace)
#
# Press Ctrl-C to stop watching.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../backup/lib/common.sh"

INTERVAL=15
FILTER_KS=""
FILTER_TABLE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval) INTERVAL="$2";    shift 2 ;;
        --keyspace) FILTER_KS="$2";   shift 2 ;;
        --table)    FILTER_TABLE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "Watching compaction progress (Ctrl-C to stop, refresh every ${INTERVAL}s)"
echo "Node: $(hostname -s)  —  $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

while true; do
    STATS=$("${NODETOOL}" compactionstats 2>/dev/null)

    ACTIVE=$(echo "${STATS}" | grep -c "^compaction" || true)

    echo "──────────────────────────────────────────────────────────────────"
    echo "  $(date '+%H:%M:%S')  Active compactions: ${ACTIVE}"
    echo ""

    if [[ -n "${FILTER_KS}" ]]; then
        FILTER="${FILTER_KS}"
        [[ -n "${FILTER_TABLE}" ]] && FILTER="${FILTER_KS}.${FILTER_TABLE}"
        echo "${STATS}" | grep -i "${FILTER}" || echo "  (no active compactions for ${FILTER})"
    else
        echo "${STATS}" | head -60
    fi

    # Also show SSTable count trend if a keyspace is specified
    if [[ -n "${FILTER_KS}" ]]; then
        echo ""
        SSTABLE_COUNT=$("${NODETOOL}" tablestats "${FILTER_KS}" 2>/dev/null \
            | grep "SSTable count:" | awk '{sum+=$NF} END{print sum}')
        echo "  Total SSTables in ${FILTER_KS}: ${SSTABLE_COUNT:-N/A}"
    fi

    sleep "${INTERVAL}"
done
