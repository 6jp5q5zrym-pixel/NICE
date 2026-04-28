#!/usr/bin/env bash
# Installs cron entries for all Cassandra backup jobs.
# Run once per node as root (or the cassandra OS user).
# Scripts run on all nodes but only the primary CPD node should run
# daily_snapshot.sh – set PRIMARY_CPD_NODE to this host's hostname.
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
50 0 * * * ${CASSANDRA_USER} ${SCRIPT_DIR}/schema_backup.sh >> /var/log/cassandra/backup/schema_backup.log 2>&1

# Daily full snapshot – 01:00
0 1 * * * ${CASSANDRA_USER} ${SCRIPT_DIR}/daily_snapshot.sh >> /var/log/cassandra/backup/daily_snapshot.log 2>&1

# Hourly commit log backup
0 * * * * ${CASSANDRA_USER} ${SCRIPT_DIR}/commitlog_backup.sh >> /var/log/cassandra/backup/commitlog_backup.log 2>&1

# Semiannual archive – January 1 and July 1 at 02:00
0 2 1 1,7 * ${CASSANDRA_USER} ${SCRIPT_DIR}/semiannual_archive.sh >> /var/log/cassandra/backup/semiannual_archive.log 2>&1
EOF

chmod 0644 "${CRON_FILE}"
echo "Cron entries installed in ${CRON_FILE}"
echo "Primary CPD node for snapshots: ${PRIMARY_CPD_NODE}"
echo ""
echo "NOTE: daily_snapshot.sh and semiannual_archive.sh should only run on the"
echo "      primary CPD node. Remove those entries from secondary CPD nodes."
