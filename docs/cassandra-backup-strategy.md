# 3.7.2 Estrategia de backup y recuperación – Cassandra

**Producto:** DataStax Enterprise (DSE) 6.8.36  
**OS:** Linux  
**Sistema integrado:** IFM (Windows)  
**Herramienta de backup:** Cohesity (corporativa)

---

## Arquitectura del clúster

Cassandra opera en topología **activo-activo** distribuida en dos CPDs. Los datos se replican automáticamente entre CPDs, lo que garantiza continuidad del servicio ante la caída completa de un CPD.

| Entorno        | Nodos | Retención diaria |
|----------------|-------|-----------------|
| Desarrollo     | 3     | 30 días         |
| Pre-producción | 3     | 30 días         |
| Producción     | 6     | 30 días         |

El backup se realiza **desde un único CPD seleccionado** (CPD primario). Dado que Cassandra replica los datos entre CPDs, esta copia es representativa del estado completo del clúster.

---

## Tipos de backup

### 1. Backup diario – snapshot completo

| Parámetro   | Valor                               |
|-------------|-------------------------------------|
| Frecuencia  | Diaria – 01:00                      |
| Mecanismo   | `nodetool snapshot` en todos los nodos |
| Retención   | 30 días (3 entornos)                |
| Script      | `scripts/cassandra/backup/daily_snapshot.sh` |

El snapshot se realiza **sin detener el servicio** (online backup). Antes del snapshot se ejecuta `nodetool flush` para volcar memtables a disco y garantizar consistencia.

Flujo:
1. `schema_backup.sh` exporta el esquema CQL (00:50).
2. `daily_snapshot.sh` realiza `nodetool flush` + `nodetool snapshot`.
3. Los ficheros del snapshot se exportan a `SNAPSHOT_EXPORT_DIR`.
4. Cohesity ingiere `SNAPSHOT_EXPORT_DIR` y `schema_backups/` según su política de protección.
5. El snapshot in-place se elimina para liberar disco.

### 2. Backup de commit logs – backup de cambios

| Parámetro   | Valor                                    |
|-------------|------------------------------------------|
| Frecuencia  | Cada hora                                |
| Mecanismo   | Copia de segmentos `CommitLog-*.log`     |
| Retención   | 30 días                                  |
| RPO         | ≈ 1 hora                                 |
| Script      | `scripts/cassandra/backup/commitlog_backup.sh` |

Permite la recuperación a un punto en el tiempo (PITR) combinando el snapshot más reciente con la reaplicación de commit logs hasta el momento del incidente.

### 3. Backup del esquema CQL

| Parámetro   | Valor                                         |
|-------------|-----------------------------------------------|
| Frecuencia  | Diaria – 00:50 (previo al snapshot)           |
| Contenido   | Keyspaces, tablas, columnas, índices, PKs      |
| Retención   | 30 días                                       |
| Script      | `scripts/cassandra/backup/schema_backup.sh`   |

El esquema se exporta mediante `DESCRIBE FULL SCHEMA` desde `cqlsh` y se comprime (gzip). Es imprescindible para restauraciones completas del clúster desde cero, ya que los datos no pueden cargarse sin las definiciones de tabla previas.

### 4. Archivado de largo plazo (solo producción)

| Parámetro   | Valor                                            |
|-------------|--------------------------------------------------|
| Frecuencia  | Semestral (1 enero y 1 julio)                    |
| Contenido   | Snapshot completo + esquema CQL                  |
| Retención   | 10 años                                          |
| Script      | `scripts/cassandra/backup/semiannual_archive.sh` |

Cada archivo incluye un checksum SHA-256 para verificación de integridad. La política de retención de 10 años se gestiona en Cohesity/almacenamiento de largo plazo.

---

## Estrategia de recuperación ante desastres (producción)

### Caso 1 – Error lógico (borrado accidental / corrupción de datos)

1. Identificar la ventana temporal del incidente.
2. Restaurar el snapshot diario más próximo anterior al incidente:
   ```bash
   scripts/cassandra/restore/restore_snapshot.sh \
     --snapshot /ruta/al/snapshot/daily_YYYYMMDD_HHMMSS
   ```
3. Replay de commit logs hasta el momento previo al incidente (PITR):
   ```bash
   scripts/cassandra/restore/restore_snapshot.sh \
     --snapshot /ruta/al/snapshot/daily_YYYYMMDD_HHMMSS \
     --commitlog-dir /var/lib/cassandra/commitlog_staging \
     --target-time "2026-01-01T09:30:00"
   ```
4. Verificar consistencia con `nodetool repair --full`.

### Caso 2 – Caída completa de un CPD

No requiere restauración. La arquitectura activo-activo garantiza continuidad del servicio: el CPD restante sigue operativo con los datos replicados. Cuando el CPD caído vuelva al servicio, Cassandra sincroniza automáticamente los nodos mediante `hinted handoff` y `read repair`.

---

## Planificación de tareas (cron)

```
# Schema export (antes del snapshot)
50 0 * * *  cassandra  /opt/cassandra/backup/schema_backup.sh

# Snapshot diario
0  1 * * *  cassandra  /opt/cassandra/backup/daily_snapshot.sh

# Commit logs cada hora
0  * * * *  cassandra  /opt/cassandra/backup/commitlog_backup.sh

# Archivo semestral
0  2 1 1,7 * cassandra  /opt/cassandra/backup/semiannual_archive.sh
```

Instalación automatizada: `scripts/cassandra/backup/install_cron.sh`

> **Nota:** `daily_snapshot.sh` y `semiannual_archive.sh` solo deben ejecutarse en los nodos del **CPD primario**. En los nodos del CPD secundario deben eliminarse esas entradas de cron.

---

## Integración con Cohesity

Cohesity gestiona el transporte, la deduplicación y la retención de los backups. Los scripts de esta documentación se encargan de la parte Cassandra-nativa (snapshots, exportación de datos, esquema). Cohesity debe configurarse para proteger las siguientes rutas en cada nodo:

| Ruta                                      | Contenido               |
|-------------------------------------------|-------------------------|
| `/var/lib/cassandra/snapshots_export`     | Snapshots diarios       |
| `/var/lib/cassandra/schema_backups`       | Esquemas CQL            |
| `/var/lib/cassandra/commitlog_staging`    | Commit logs por hora    |
| `/mnt/longterm_archive/cassandra`         | Archivos semestrales    |

---

## Resumen de RPO / RTO

| Escenario                      | RPO       | RTO estimado   |
|--------------------------------|-----------|----------------|
| Error lógico (con PITR)        | ≈ 1 hora  | 2-4 horas      |
| Error lógico (solo snapshot)   | ≈ 24 horas| 1-2 horas      |
| Caída de CPD (activo-activo)   | 0         | 0 (sin restore)|
| Pérdida total del clúster      | ≈ 1 hora  | 4-8 horas      |
