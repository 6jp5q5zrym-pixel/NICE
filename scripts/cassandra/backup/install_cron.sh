#!/usr/bin/env bash
# Installs cron entries for this node based on its hostname.
#
# Backup assignment:
#   IBNICECAS01PRO  →  schema + daily snapshot + commit log + semiannual
#   IBNICECAS02PRO  →  (no backup jobs — data identical to 01PRO, same DC)
#   IBNICECAS03PRO  →  commit log only (PITR resilience if 01PRO is down)
#   IBNICECAS04PRO  →  (no backup jobs — data identical to 03PRO, same DC)
#
# Run as root on each node:
#   sudo bash install_cron.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASSANDRA_USER="${CASSANDRA_USER:-cassandra}"
ALERT_EMAIL="${ALERT_EMAIL:-}"   # set via env or edit here: export ALERT_EMAIL=admin@ibercaja.es
CRON_FILE="/etc/cron.d/cassandra_backup"
THIS_HOST=$(hostname -s)

MONITOR_SCRIPT="${SCRIPT_DIR}/../maintenance/backup_monitor.sh"

install_primary() {
    cat > "${CRON_FILE}" <<EOF
# Cassandra backup jobs – managed by install_cron.sh
# Node role: PRIMARY  (schema + daily + commitlog + semiannual)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# MAILTO: cron envía el stderr del monitor por email si el check falla.
# Descomentar cuando SMTP esté habilitado en ibsmtp.ibercaja.es.
# MAILTO=${ALERT_EMAIL}

# Schema export – daily at 00:50 (runs before daily snapshot)
50 0 * * * ${CASSANDRA_USER} ${SCRIPT_DIR}/schema_backup.sh

# Daily full snapshot – 01:00
0 1 * * * ${CASSANDRA_USER} ${SCRIPT_DIR}/daily_snapshot.sh

# Hourly commit log backup
0 * * * * ${CASSANDRA_USER} ${SCRIPT_DIR}/commitlog_backup.sh

# Semiannual archive – 1 January and 1 July at 02:00
0 2 1 1,7 * ${CASSANDRA_USER} ${SCRIPT_DIR}/semiannual_archive.sh

# Monitoring: verify daily backup arrived (runs at 05:00 — backup finishes ~03:30)
0 5 * * * ${CASSANDRA_USER} ${MONITOR_SCRIPT} --check daily

# Monitoring: verify commit log arrived every hour at :15
15 * * * * ${CASSANDRA_USER} ${MONITOR_SCRIPT} --check commitlog

# Monitoring: verify semiannual archive (runs daily, skips silently outside Jan/Jul)
0 6 * * * ${CASSANDRA_USER} ${MONITOR_SCRIPT} --check semiannual
EOF
    echo "Installed PRIMARY cron (schema + daily + commitlog + semiannual + monitoring) on ${THIS_HOST}"
}

install_commitlog_only() {
    cat > "${CRON_FILE}" <<EOF
# Cassandra backup jobs – managed by install_cron.sh
# Node role: COMMITLOG  (commit log only for PITR resilience)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# MAILTO=${ALERT_EMAIL}

# Hourly commit log backup
0 * * * * ${CASSANDRA_USER} ${SCRIPT_DIR}/commitlog_backup.sh

# Monitoring: verify commit log arrived every hour at :15
15 * * * * ${CASSANDRA_USER} ${MONITOR_SCRIPT} --check commitlog
EOF
    echo "Installed COMMITLOG-ONLY cron on ${THIS_HOST}"
}

remove_cron() {
    if [[ -f "${CRON_FILE}" ]]; then
        rm -f "${CRON_FILE}"
        echo "Removed existing cron file on ${THIS_HOST}"
    else
        echo "No cron file to remove on ${THIS_HOST}"
    fi
    echo "This node has no backup role — no cron installed."
}

case "${THIS_HOST}" in
    IBNICECAS01PRO) install_primary ;;
    IBNICECAS03PRO) install_commitlog_only ;;
    IBNICECAS02PRO|IBNICECAS04PRO) remove_cron ;;
    *)
        echo "WARNING: hostname '${THIS_HOST}' not recognised."
        echo "Valid hostnames: IBNICECAS01PRO, IBNICECAS02PRO, IBNICECAS03PRO, IBNICECAS04PRO"
        echo "No cron file written."
        exit 1
        ;;
esac

if [[ -f "${CRON_FILE}" ]]; then
    chmod 0644 "${CRON_FILE}"
    chown root:root "${CRON_FILE}"
fi
