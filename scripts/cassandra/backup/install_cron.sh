#!/usr/bin/env bash
# Installs cron entries for all Cassandra backup jobs.
# Run once per node as root (or the cassandra OS user).
# Scripts run on all nodes but only the primary CPD node should run
# daily_snapshot.sh – set PRIMARY_CPD_NODE to this host's hostname.
#
# NOTE: semiannual_archive.sh is NOT installed here.
# Add it manually after go-live with the confirmed date:
#   echo "0 2 <DD> <MM> * cassandra <SCRIPT_DIR>/semiannual_archive.sh >> /logs/cassandra/backup/semiannual_archive.log 2>&1" \
#     >> /etc/cron.d/cassandra_backup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASSANDRA_USER="${CASSANDRA_USER:-cassandra}"
PRIMARY_CPD_NODE="${PRIMARY_CPD_NODE:-$(hostname)}"

CRON_FILE="/etc/cron.d/cassandra_backup"

cat > "${CRON_FILE}" <<EOF
# Cassandra backup jobs – managed by install_cron.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Schema export – daily at 00:50 (before snapshot)
50 0 * * * ${CASSANDRA_USER} ${SCRIPT_DIR}/schema_backup.sh >> /logs/cassandra/backup/schema_backup.log 2>&1

# Daily full snapshot – 01:00  (retention: 30 days, purged automatically by the script)
0 1 * * * ${CASSANDRA_USER} ${SCRIPT_DIR}/daily_snapshot.sh >> /logs/cassandra/backup/daily_snapshot.log 2>&1

# Hourly commit log backup
0 * * * * ${CASSANDRA_USER} ${SCRIPT_DIR}/commitlog_backup.sh >> /logs/cassandra/backup/commitlog_backup.log 2>&1

# Semiannual archive: add manually after go-live confirmation.
# Example (replace DD and MM with the actual date):
# 0 2 DD MM * ${CASSANDRA_USER} ${SCRIPT_DIR}/semiannual_archive.sh >> /logs/cassandra/backup/semiannual_archive.log 2>&1
EOF

chmod 0644 "${CRON_FILE}"
echo "Cron entries installed in ${CRON_FILE}"
echo "Primary CPD node for snapshots: ${PRIMARY_CPD_NODE}"
echo ""
echo "PENDING: add semiannual_archive.sh cron entry manually after go-live date is confirmed."
echo "NOTE: daily_snapshot.sh should only run on the primary CPD node."
echo "      Remove that entry from secondary CPD nodes."
