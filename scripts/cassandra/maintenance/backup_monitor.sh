#!/usr/bin/env bash
# Checks that backup files appeared in the Cohesity share within the expected window.
# Logs a WARNING and exits with code 1 if any check fails.
# Designed to run from cron shortly after each backup window closes.
#
# Cron schedule (add to IBNICECAS01PRO):
#   Daily check    → 05:00  (daily backup should finish by ~03:30)
#   Commitlog check → every hour at :15  (commitlog runs at :00)
#
# Usage:
#   backup_monitor.sh --check daily|commitlog|semiannual [--node <hostname>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../backup/lib/common.sh"

COHESITY_DAILY_DIR="${COHESITY_DAILY_DIR:-/mnt/cohesity/daily}"
COHESITY_COMMITLOG_DIR="${COHESITY_COMMITLOG_DIR:-/mnt/cohesity/commitlogs}"
COHESITY_ARCHIVE_DIR="${COHESITY_ARCHIVE_DIR:-/mnt/cohesity/archive}"
LOG_FILE="${LOG_DIR}/backup_monitor.log"

# Max age in minutes before a backup is considered missing
DAILY_MAX_AGE_MIN="${DAILY_MAX_AGE_MIN:-240}"       # 4h — daily starts at 01:00, should finish by 03:30
COMMITLOG_MAX_AGE_MIN="${COMMITLOG_MAX_AGE_MIN:-75}" # 75min — runs every hour

CHECK=""
NODE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK="$2"; shift 2 ;;
        --node)  NODE="$2";  shift 2 ;;
        *) log "ERROR" "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "${CHECK}" ]] && { log "ERROR" "--check is required (daily|commitlog|semiannual)"; exit 1; }

exec >> "${LOG_FILE}" 2>&1

HOSTNAME_SHORT="${NODE:-$(hostname -s)}"
FAILED=0

check_daily() {
    local pattern="cassandra_backup_${HOSTNAME_SHORT}_$(date +%Y%m%d)*.tar"
    local found
    found=$(find "${COHESITY_DAILY_DIR}" -name "${pattern}" -mmin "-${DAILY_MAX_AGE_MIN}" 2>/dev/null | head -1)

    if [[ -z "${found}" ]]; then
        log "WARN" "MISSING daily backup for ${HOSTNAME_SHORT} — no file matching '${pattern}' in ${COHESITY_DAILY_DIR} newer than ${DAILY_MAX_AGE_MIN} min"
        log "WARN" "Manual recovery: sudo ${SCRIPT_DIR}/../backup/daily_snapshot.sh"
        FAILED=1
    else
        local size
        size=$(du -sh "${found}" | cut -f1)
        log "INFO" "OK daily backup: $(basename "${found}") (${size})"

        # Verify sha256 if present
        local sha_file="${found}.sha256"
        if [[ -f "${sha_file}" ]]; then
            if sha256sum --check --status "${sha_file}" 2>/dev/null; then
                log "INFO" "OK sha256 verified: $(basename "${found}")"
            else
                log "WARN" "SHA256 MISMATCH for $(basename "${found}") — file may be corrupt"
                FAILED=1
            fi
        else
            log "WARN" "No sha256 file found for $(basename "${found}")"
        fi
    fi
}

check_commitlog() {
    local pattern="cassandra_commitlog_${HOSTNAME_SHORT}_*.tar.gz"
    local found
    found=$(find "${COHESITY_COMMITLOG_DIR}" -name "${pattern}" -mmin "-${COMMITLOG_MAX_AGE_MIN}" 2>/dev/null | head -1)

    if [[ -z "${found}" ]]; then
        log "WARN" "MISSING commit log for ${HOSTNAME_SHORT} — no file matching '${pattern}' in ${COHESITY_COMMITLOG_DIR} newer than ${COMMITLOG_MAX_AGE_MIN} min"
        log "WARN" "Manual recovery: sudo ${SCRIPT_DIR}/../backup/commitlog_backup.sh"
        FAILED=1
    else
        local size
        size=$(du -sh "${found}" | cut -f1)
        log "INFO" "OK commit log: $(basename "${found}") (${size})"
    fi
}

check_semiannual() {
    # Only meaningful in January and July — skip other months silently
    local month
    month=$(date +%m)
    if [[ "${month}" != "01" && "${month}" != "07" ]]; then
        log "INFO" "Semiannual check skipped — not January or July"
        return
    fi

    local year month_day pattern
    year=$(date +%Y)
    month_day=$(date +%m%d)
    pattern="cassandra_archive_${HOSTNAME_SHORT}_${year}${month_day}*.tar"

    local found
    found=$(find "${COHESITY_ARCHIVE_DIR}" -name "${pattern}" 2>/dev/null | head -1)

    if [[ -z "${found}" ]]; then
        log "WARN" "MISSING semiannual archive for ${HOSTNAME_SHORT} — no file matching '${pattern}' in ${COHESITY_ARCHIVE_DIR}"
        log "WARN" "Manual recovery: sudo ${SCRIPT_DIR}/../backup/semiannual_archive.sh"
        FAILED=1
    else
        local size
        size=$(du -sh "${found}" | cut -f1)
        log "INFO" "OK semiannual archive: $(basename "${found}") (${size})"
    fi
}

log "INFO" "=== Backup monitor check: ${CHECK} | node: ${HOSTNAME_SHORT} ==="

case "${CHECK}" in
    daily)       check_daily ;;
    commitlog)   check_commitlog ;;
    semiannual)  check_semiannual ;;
    *) log "ERROR" "Unknown check type '${CHECK}'. Valid: daily|commitlog|semiannual"; exit 1 ;;
esac

if [[ ${FAILED} -eq 0 ]]; then
    log "INFO" "=== All checks passed ==="
else
    log "WARN" "=== CHECK FAILED — review warnings above and relaunch manually if needed ==="
fi

exit ${FAILED}
