# 3.7.2 Estrategia de backup y recuperación – Cassandra

**Producto:** DataStax Enterprise (DSE) 6.8.36  
**OS:** Linux  
**Sistema integrado:** IFM (Windows)  
**Herramienta de backup:** Cohesity (corporativa) – integración por pickup de ficheros

---

## Herramienta nativa de backup: `nodetool snapshot`

Cassandra no dispone de un mecanismo de exportación tipo `mysqldump`. Su herramienta nativa de backup es **`nodetool snapshot`**, que genera una imagen consistente de los datos en disco sin detener el servicio.

### Cómo funciona internamente

Cassandra persiste los datos en ficheros binarios denominados **SSTables**:

```
/var/lib/cassandra/data/
  └── keyspace_ifm/
        └── tabla_clientes-a1b2c3/   ← tabla con UUID interno
              ├── mc-1-big-Data.db    ← datos
              ├── mc-1-big-Index.db   ← índice
              └── mc-1-big-Filter.db  ← bloom filter
```

`nodetool snapshot` crea **hard links** (instantáneos, sin duplicar datos en disco) a los SSTables activos bajo un directorio `snapshots/<tag>/`. Esos ficheros pueden copiarse y empaquetarse mientras Cassandra sigue operativa.

### Dos capas imprescindibles para restaurar

| Capa | Contenido | Herramienta |
|------|-----------|-------------|
| **Esquema CQL** | Keyspaces, tablas, columnas, índices, PKs | `cqlsh DESCRIBE FULL SCHEMA` |
| **Datos** | SSTables (binario, formato propietario Cassandra) | `nodetool snapshot` |

Ambas capas deben restaurarse juntas y en ese orden: primero el esquema (para que existan las tablas), después los datos. Si falta alguna, la restauración es inviable.

---

## Arquitectura del clúster

Cassandra opera en topología **activo-activo** distribuida en dos CPDs. Los datos se replican automáticamente entre CPDs, garantizando continuidad ante la caída completa de un CPD.

| Entorno        | Nodos | Retención diaria |
|----------------|-------|-----------------|
| Desarrollo     | 3     | 30 días         |
| Pre-producción | 3     | 30 días         |
| Producción     | 6     | 30 días         |

El backup se ejecuta en los nodos del **CPD primario** únicamente. Al ser una arquitectura replicada, esta copia es representativa del estado completo del clúster.

---

## Integración con Cohesity – modelo pickup de ficheros

No se utiliza la integración nativa Cohesity↔Cassandra (que requiere nodos de cómputo Cohesity). En su lugar, los scripts producen paquetes `.tar.gz` auto-contenidos que Cohesity recoge de un directorio de entrega:

```
Nodo Cassandra (Linux)                         Cohesity
──────────────────────────────                 ─────────
                                               
1. cqlsh DESCRIBE FULL SCHEMA                  
2. nodetool flush                              
3. nodetool snapshot                           
4. cp SSTables → staging/                     
5. tar -czf cassandra_backup_*.tar.gz          
6. mv *.tar.gz → /mnt/cohesity_pickup/  ──►  Cohesity recoge,
                                              almacena y gestiona
                                              retención / dedup
```

Cada paquete `.tar.gz` contiene:

```
cassandra_backup_<nodo>_<timestamp>/
├── schema/
│   └── schema.cql          ← DESCRIBE FULL SCHEMA completo
├── data/
│   └── <keyspace>/
│       └── <tabla-uuid>/   ← SSTables de cada tabla
│             ├── mc-1-big-Data.db
│             └── ...
└── manifest.json           ← metadatos (nodo, timestamp, DSE version, keyspaces)
```

---

## Tipos de backup

### 1. Backup diario – snapshot completo

| Parámetro    | Valor |
|--------------|-------|
| Frecuencia   | Diaria – 01:00 |
| Contenido    | Esquema CQL + SSTables de todos los keyspaces |
| Retención    | 30 días |
| Pickup dir   | `/mnt/cohesity_pickup/cassandra/daily/` |
| Script       | `scripts/cassandra/backup/daily_snapshot.sh` |

Flujo del script:
1. Exporta `DESCRIBE FULL SCHEMA` a `schema/schema.cql`
2. Ejecuta `nodetool flush` (vuelca memtables)
3. Ejecuta `nodetool snapshot --tag daily_<timestamp>`
4. Copia los SSTables del snapshot a un directorio de staging
5. Elimina el snapshot in-place de Cassandra (libera disco)
6. Genera `manifest.json` con metadatos
7. Empaqueta todo en `cassandra_backup_<nodo>_<timestamp>.tar.gz` + SHA-256
8. Mueve el paquete a `/mnt/cohesity_pickup/cassandra/daily/`
9. Purga paquetes locales con más de 30 días

### 2. Backup de commit logs – backup de cambios

| Parámetro  | Valor |
|------------|-------|
| Frecuencia | Cada hora |
| Contenido  | Segmentos `CommitLog-*.log` sellados |
| Retención  | 30 días |
| RPO        | ≈ 1 hora |
| Pickup dir | `/mnt/cohesity_pickup/cassandra/commitlogs/` |
| Script     | `scripts/cassandra/backup/commitlog_backup.sh` |

El script ejecuta `nodetool flush` para sellar el segmento activo y luego copia todos los segmentos `CommitLog-*.log` a un paquete `.tar.gz`. Combinado con el snapshot diario, permite recuperación a un punto en el tiempo (PITR).

### 3. Backup del esquema CQL (standalone)

| Parámetro  | Valor |
|------------|-------|
| Frecuencia | Diaria – 00:50 |
| Contenido  | Salida de `DESCRIBE FULL SCHEMA` comprimida con gzip |
| Retención  | 30 días |
| Pickup dir | `/mnt/cohesity_pickup/cassandra/schema/` |
| Script     | `scripts/cassandra/backup/schema_backup.sh` |

El esquema ya va embebido dentro del paquete diario. Este script standalone existe para restauraciones de esquema rápidas sin necesidad de desempaquetar el backup completo.

### 4. Archivado semestral de largo plazo (solo producción)

| Parámetro  | Valor |
|------------|-------|
| Frecuencia | Semestral (1 enero y 1 julio – 02:00) |
| Contenido  | Snapshot completo + esquema CQL |
| Retención  | 10 años (política en Cohesity) |
| Pickup dir | `/mnt/cohesity_pickup/cassandra/archive/` |
| Script     | `scripts/cassandra/backup/semiannual_archive.sh` |

Mismo proceso que el diario pero con tag `archive_<timestamp>`. Incluye SHA-256 para verificación de integridad. La retención de 10 años se configura en la política de almacenamiento de Cohesity.

---

## Estrategia de recuperación ante desastres (producción)

### Caso 1 – Error lógico (borrado accidental / corrupción de datos)

```bash
# Solo snapshot (estado al inicio del día)
restore_snapshot.sh \
  --package /mnt/cohesity_pickup/cassandra/daily/cassandra_backup_node1_20260428_010000.tar.gz

# Con PITR (recupera hasta el momento previo al incidente)
restore_snapshot.sh \
  --package /mnt/cohesity_pickup/cassandra/daily/cassandra_backup_node1_20260428_010000.tar.gz \
  --commitlogs /mnt/cohesity_pickup/cassandra/commitlogs \
  --target-time "2026-04-28T09:30:00"
```

El script:
1. Extrae el `.tar.gz`
2. Detiene Cassandra
3. Restaura el esquema CQL vía `cqlsh`
4. Copia los SSTables al directorio de datos
5. Si se indica `--commitlogs`, aplica los segmentos de commit log hasta `--target-time`
6. Arranca Cassandra y lanza `nodetool repair` para sincronizar réplicas

### Caso 2 – Caída completa de un CPD

No requiere restauración. La arquitectura activo-activo garantiza continuidad: el CPD restante sigue operativo. Al recuperarse el CPD caído, Cassandra sincroniza los nodos automáticamente mediante `hinted handoff` y `read repair`.

---

## Planificación de tareas (cron)

```
# Schema standalone – 00:50 diario
50 0 * * *   cassandra  /opt/cassandra/backup/schema_backup.sh

# Snapshot diario con schema embebido – 01:00
0  1 * * *   cassandra  /opt/cassandra/backup/daily_snapshot.sh

# Commit logs – cada hora
0  * * * *   cassandra  /opt/cassandra/backup/commitlog_backup.sh

# Archivo semestral – 1 enero y 1 julio a las 02:00 (solo nodos CPD primario)
0  2 1 1,7 * cassandra  /opt/cassandra/backup/semiannual_archive.sh
```

Instalación automática: `scripts/cassandra/backup/install_cron.sh`

> Los scripts de snapshot y archive solo deben ejecutarse en los nodos del CPD primario. En los nodos del CPD secundario solo debe activarse el cron de commit logs.

---

## Directorios de pickup para Cohesity

| Ruta en nodo Cassandra | Contenido | Frecuencia |
|------------------------|-----------|------------|
| `/mnt/cohesity_pickup/cassandra/daily/` | `cassandra_backup_<nodo>_<ts>.tar.gz` | Diaria |
| `/mnt/cohesity_pickup/cassandra/commitlogs/` | `cassandra_commitlog_<nodo>_<ts>.tar.gz` | Horaria |
| `/mnt/cohesity_pickup/cassandra/schema/` | `schema_<nodo>_<ts>.cql.gz` | Diaria |
| `/mnt/cohesity_pickup/cassandra/archive/` | `cassandra_archive_<nodo>_<ts>.tar.gz` | Semestral |

Cohesity debe configurarse para recoger estos directorios con las siguientes políticas:

| Directorio | Política Cohesity | Retención |
|------------|------------------|-----------|
| `daily/`   | `cassandra-daily` | 30 días |
| `commitlogs/` | `cassandra-commitlog` | 30 días |
| `schema/`  | `cassandra-schema` | 30 días |
| `archive/` | `cassandra-longterm` | 10 años |

---

## Resumen RPO / RTO

| Escenario | RPO | RTO estimado |
|---|---|---|
| Error lógico con PITR | ≈ 1 hora | 2-4 horas |
| Error lógico solo con snapshot | ≈ 24 horas | 1-2 horas |
| Caída de un CPD (activo-activo) | 0 | 0 (sin restore) |
| Pérdida total del clúster | ≈ 1 hora | 4-8 horas |
