-- ============================================================
-- DSE 6.8.36 PRODUCCIÓN – DDL keyspaces
-- Ejecutar en orden desde CQLSH apuntando a cualquier nodo.
-- ============================================================

-- ─── 1. ALTERAR KEYSPACES DE SISTEMA ────────────────────────
-- Por defecto usan SimpleStrategy RF=1, lo que es INSEGURO en producción multi-DC.
-- Después de cada ALTER: nodetool repair --full <keyspace>
-- (repair puede tardar varios minutos; ejecutar en horario de bajo tráfico)

-- system_auth: contiene roles y contraseñas → CRÍTICO replicar
ALTER KEYSPACE system_auth
  WITH REPLICATION = {
    'class': 'NetworkTopologyStrategy',
    'CPD1': 2,
    'CPD2': 2
  };

-- system_distributed: historial de reparaciones y estado Paxos (LWT)
ALTER KEYSPACE system_distributed
  WITH REPLICATION = {
    'class': 'NetworkTopologyStrategy',
    'CPD1': 2,
    'CPD2': 2
  };

-- system_traces: datos de tracing (solo relevante si se activa TRACING)
ALTER KEYSPACE system_traces
  WITH REPLICATION = {
    'class': 'NetworkTopologyStrategy',
    'CPD1': 2,
    'CPD2': 2
  };

-- dse_security: roles y permisos DSE (CRÍTICO en clústeres con autenticación DSE)
ALTER KEYSPACE dse_security
  WITH REPLICATION = {
    'class': 'NetworkTopologyStrategy',
    'CPD1': 2,
    'CPD2': 2
  };

-- dse_leases: uso interno de DSE (coordinación de tareas distribuidas)
ALTER KEYSPACE dse_leases
  WITH REPLICATION = {
    'class': 'NetworkTopologyStrategy',
    'CPD1': 2,
    'CPD2': 2
  };

-- ─── 2. REPARAR KEYSPACES DE SISTEMA DESPUÉS DE ALTERAR ─────
-- Ejecutar desde el shell tras cada ALTER (no desde cqlsh):
--
--   /opt/datastax/dse-6.8.36/bin/nodetool repair --full system_auth
--   /opt/datastax/dse-6.8.36/bin/nodetool repair --full system_distributed
--   /opt/datastax/dse-6.8.36/bin/nodetool repair --full system_traces
--   /opt/datastax/dse-6.8.36/bin/nodetool repair --full dse_security
--   /opt/datastax/dse-6.8.36/bin/nodetool repair --full dse_leases

-- ─── 3. CREAR KEYSPACES DE APLICACIÓN ───────────────────────
-- Crear en PRODUCCIÓN antes de iniciar migración de datos.
-- Los nombres deben coincidir con los usados en DEV/PRE (sufijo _pro en lugar de _dev/_pre).

CREATE KEYSPACE IF NOT EXISTS ff_prf_usr_pro
  WITH REPLICATION = {
    'class': 'NetworkTopologyStrategy',
    'CPD1': 2,
    'CPD2': 2
  }
  AND DURABLE_WRITES = true;

CREATE KEYSPACE IF NOT EXISTS ff_prf_anlts_pro
  WITH REPLICATION = {
    'class': 'NetworkTopologyStrategy',
    'CPD1': 2,
    'CPD2': 2
  }
  AND DURABLE_WRITES = true;

CREATE KEYSPACE IF NOT EXISTS ff_prf_sol_pro
  WITH REPLICATION = {
    'class': 'NetworkTopologyStrategy',
    'CPD1': 2,
    'CPD2': 2
  }
  AND DURABLE_WRITES = true;

-- ─── 4. VERIFICAR ────────────────────────────────────────────
-- Ejecutar para confirmar que todos los keyspaces tienen la replicación correcta:
--
--   SELECT keyspace_name, replication
--   FROM system_schema.keyspaces
--   WHERE keyspace_name IN (
--     'system_auth', 'system_distributed', 'system_traces',
--     'dse_security', 'dse_leases',
--     'ff_prf_usr_pro', 'ff_prf_anlts_pro', 'ff_prf_sol_pro'
--   );
--
-- Resultado esperado en columna 'replication' para cada keyspace:
--   {'CPD1': '2', 'CPD2': '2', 'class': 'org.apache.cassandra.locator.NetworkTopologyStrategy'}
