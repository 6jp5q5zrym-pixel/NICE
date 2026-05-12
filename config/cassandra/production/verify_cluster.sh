#!/usr/bin/env bash
# Verificación post-configuración del clúster de producción DSE 6.8.36.
# Ejecutar desde CUALQUIER nodo del clúster (como usuario cassandra o root).
# No modifica nada – solo lectura.
set -euo pipefail

NODETOOL="${NODETOOL:-/opt/datastax/dse-6.8.36/bin/nodetool}"
CQLSH="${CQLSH:-/opt/datastax/dse-6.8.36/bin/cqlsh}"
CQLSH_HOST="${CQLSH_HOST:-$(hostname -I | awk '{print $1}')}"
CQLSH_PORT="${CQLSH_PORT:-9042}"

sep() { echo; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; echo "  $1"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

sep "1. ESTADO DEL CLÚSTER (todos los nodos deben ser UN)"
"${NODETOOL}" status
echo ""
echo "Esperado: 4 nodos UN, 2 en CPD1 y 2 en CPD2"

sep "2. DISTRIBUCIÓN DE TOKENS (Owns ~50% por nodo dentro de cada DC)"
"${NODETOOL}" status ff_prf_usr_pro 2>/dev/null || "${NODETOOL}" status

sep "3. SNITCH CONFIGURADO"
"${NODETOOL}" describecluster | grep -E "(Snitch|Partitioner|Schema)"
echo ""
echo "Esperado: GossipingPropertyFileSnitch"

sep "4. REPLICACIÓN DE KEYSPACES"
"${CQLSH}" "${CQLSH_HOST}" "${CQLSH_PORT}" --execute "
SELECT keyspace_name, replication
FROM system_schema.keyspaces
WHERE keyspace_name IN (
  'system_auth', 'system_distributed', 'system_traces',
  'dse_security', 'dse_leases',
  'ff_prf_usr_pro', 'ff_prf_anlts_pro', 'ff_prf_sol_pro'
);" 2>/dev/null
echo ""
echo "Esperado: NetworkTopologyStrategy con CPD1:2 y CPD2:2 en todos"

sep "5. NODESYNC – ESTADO DEL SERVICIO"
"${NODETOOL}" nodesyncservice status 2>/dev/null || echo "NodeSync no activo (normal si no se ha habilitado por tabla)"

sep "6. HINTED HANDOFF – CONTADORES"
"${NODETOOL}" tpstats | grep -A5 "HINT"

sep "7. COMPACTACIÓN – ESTADO ACTUAL"
"${NODETOOL}" compactionstats

sep "8. RING – VERIFICAR TOKEN DISTRIBUTION"
"${NODETOOL}" ring | grep -E "(Address|CPD|UN|DN)" | head -20

echo ""
echo "Verificación completada. Revisar los puntos marcados como 'Esperado'."
