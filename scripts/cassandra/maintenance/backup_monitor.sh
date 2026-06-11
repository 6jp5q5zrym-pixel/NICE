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

# Sends alert to syslog (visible inmediatamente en /var/log/messages)
# y a stderr (cron lo captura y manda por email si MAILTO está configurado).
alert() {
    local msg="$1"
    logger -t cassandra_backup -p local0.err "ALERT [${HOSTNAME_SHORT}]: ${msg}"
    echo "[ALERT] ${msg}" >&2
}

check_daily() {
    local pattern="cassandra_backup_${HOSTNAME_SHORT}_$(date +%Y%m%d)*.tar"
    local found
    found=$(find "${COHESITY_DAILY_DIR}" -name "${pattern}" -mmin "-${DAILY_MAX_AGE_MIN}" 2>/dev/null | head -1)

    if [[ -z "${found}" ]]; then
        alert "daily backup MISSING — no file matching '${pattern}' newer than ${DAILY_MAX_AGE_MIN} min en ${COHESITY_DAILY_DIR}"
        alert "Relanzar manualmente: sudo ${SCRIPT_DIR}/../backup/daily_snapshot.sh"
        FAILED=1
    else
        local size
        size=$(du -sh "${found}" | cut -f1)
        log "INFO" "OK daily backup: $(basename "${found}") (${size})"

        local sha_file="${found}.sha256"
        if [[ -f "${sha_file}" ]]; then
            if sha256sum --check --status "${sha_file}" 2>/dev/null; then
                log "INFO" "OK sha256 verificado: $(basename "${found}")"
            else
                alert "SHA256 MISMATCH en $(basename "${found}") — fichero posiblemente corrupto"
                FAILED=1
            fi
        else
            log "WARN" "Sin fichero sha256 para $(basename "${found}")"
        fi
    fi
}

check_commitlog() {
    local pattern="cassandra_commitlog_${HOSTNAME_SHORT}_*.tar.gz"
    local found
    found=$(find "${COHESITY_COMMITLOG_DIR}" -name "${pattern}" -mmin "-${COMMITLOG_MAX_AGE_MIN}" 2>/dev/null | head -1)

    if [[ -z "${found}" ]]; then
        alert "commit log MISSING — no file matching '${pattern}' newer than ${COMMITLOG_MAX_AGE_MIN} min en ${COHESITY_COMMITLOG_DIR}"
        alert "Relanzar manualmente: sudo ${SCRIPT_DIR}/../backup/commitlog_backup.sh"
        FAILED=1
    else
        local size
        size=$(du -sh "${found}" | cut -f1)
        log "INFO" "OK commit log: $(basename "${found}") (${size})"
    fi
}

check_semiannual() {
    local month
    month=$(date +%m)
    if [[ "${month}" != "01" && "${month}" != "07" ]]; then
        log "INFO" "Semiannual check skipped — fuera de enero/julio"
        return
    fi

    local year month_day pattern
    year=$(date +%Y)
    month_day=$(date +%m%d)
    pattern="cassandra_archive_${HOSTNAME_SHORT}_${year}${month_day}*.tar"

    local found
    found=$(find "${COHESITY_ARCHIVE_DIR}" -name "${pattern}" 2>/dev/null | head -1)

    if [[ -z "${found}" ]]; then
        alert "semiannual archive MISSING — no file matching '${pattern}' en ${COHESITY_ARCHIVE_DIR}"
        alert "Relanzar manualmente: sudo ${SCRIPT_DIR}/../backup/semiannual_archive.sh"
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
