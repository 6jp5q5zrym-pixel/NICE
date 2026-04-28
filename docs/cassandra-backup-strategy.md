# 3.7.2 Estrategia de backup y recuperación – Cassandra

Este apartado describe la estrategia de backup, retención y recuperación de la base de datos Cassandra (DataStax Enterprise 6.8.36) utilizada para el almacenamiento de perfiles de los clientes de la entidad bancaria.

A continuación, se detalla la arquitectura de Cassandra por entorno:

| Entorno        | Nodos |
|----------------|-------|
| Desarrollo     | 3     |
| Pre-producción | 3     |
| Producción     | 6     |

---

## Mecanismo de protección de datos

La protección de datos de Cassandra se realizará mediante la herramienta corporativa **Cohesity**, actuando como sistema de almacenamiento y gestión de retención de los paquetes de backup.

Dado que Cassandra es una base de datos CQL distribuida, el backup se diseñará a nivel de clúster, protegiendo todos los nodos que lo componen. El proceso se ejecutará de forma consistente desde un único CPD seleccionado (CPD primario), dado que Cassandra replica los datos entre CPDs.

### Modelo de integración con Cohesity

La integración entre Cassandra y Cohesity se realizará mediante un modelo de **entrega de ficheros** (*file pickup*), sin integración nativa entre ambas plataformas. Este modelo funciona de la siguiente manera:

1. Las herramientas nativas de Cassandra (`nodetool` y `cqlsh`) generan en cada nodo un paquete de backup auto-contenido en formato `.tar.gz`.
2. Dicho paquete incluye tanto el esquema CQL como los datos (SSTables), y se deposita en un directorio de entrega compartido accesible por Cohesity.
3. Cohesity recoge los paquetes de ese directorio y los almacena aplicando las políticas de retención y deduplicación definidas.

```
Nodo Cassandra (Linux)                         Cohesity
──────────────────────────────────             ─────────────────────────
1. cqlsh → exporta esquema CQL
2. nodetool flush + snapshot → datos
3. Empaqueta en .tar.gz con SHA-256
4. Deposita en /mnt/cohesity_pickup/  ──────►  Recoge, almacena y gestiona
                                               retención según política
```

Cada paquete `.tar.gz` es auto-contenido e incluye:

- **Esquema CQL**: definición completa de keyspaces, tablas, columnas, índices y claves primarias, obtenida mediante `DESCRIBE FULL SCHEMA` en `cqlsh`. Es imprescindible para restauraciones completas desde cero, ya que los datos en formato SSTable no pueden recuperarse sin conocer previamente la estructura de las tablas.
- **Datos**: ficheros SSTable generados por `nodetool snapshot`, que constituyen una imagen consistente y punto en el tiempo de todos los datos del nodo.
- **Manifiesto**: fichero de metadatos con información del nodo, timestamp, versión de DSE y keyspaces incluidos.

---

## Tipos de backup

### Backup diario (equivalente al backup full)

Se realizará un snapshot consistente de Cassandra en todos los nodos del clúster de manera diaria, garantizando una imagen coherente del clúster. El proceso no requiere detener el servicio.

La herramienta nativa utilizada es `nodetool snapshot`, que genera una imagen de los SSTables en disco mediante hard links, combinada con la exportación del esquema CQL mediante `cqlsh`. Ambos elementos se empaquetan juntos en un único fichero `.tar.gz` por nodo.

El periodo de retención será de **30 días** para los tres entornos (desarrollo, pre-producción y producción).

### Backup de cambios (equivalente al backup de logs)

Se realizará una copia de seguridad de los commit logs de Cassandra con una frecuencia de **1 hora** y un periodo de retención de **30 días**. Los commit logs registran todas las escrituras recibidas por el nodo y permiten, combinados con el snapshot diario, recuperar el estado de la base de datos en cualquier punto intermedio.

Este mecanismo reduce la pérdida máxima de datos en caso de incidente, estableciendo un **RPO aproximado de 1 hora**.

### Backup del esquema CQL

Adicionalmente al esquema embebido en cada paquete diario, se realizará una exportación independiente del esquema CQL con frecuencia diaria. Esta copia standalone permite restaurar o auditar la estructura de la base de datos sin necesidad de desempaquetar el backup completo de datos.

### Retención y archivado en el entorno de producción

Se establecerá un archivado de largo plazo con frecuencia **semestral** (1 de enero y 1 de julio) y retención de **10 años**. Cada archivo contendrá un snapshot completo de los datos y del esquema CQL, empaquetado en formato `.tar.gz` con checksum SHA-256 para verificación de integridad. La política de retención de 10 años será gestionada por Cohesity en el nivel de almacenamiento.

---

## Estrategia de recuperación ante desastres en producción

### Errores lógicos (borrados accidentales, corrupción de datos)

Se restaurará el paquete de snapshot más reciente anterior al incidente, que incluye el esquema y los datos. Si se requiere recuperación a un punto en el tiempo exacto (PITR), se reaplicarán los paquetes de commit logs desde el snapshot hasta el momento previo al incidente, utilizando la capacidad nativa de Cassandra de reproducción de commit logs con punto de parada configurable.

### Caída completa de CPD

Si el CPD restante continúa operativo, no será necesario realizar restauración alguna. La arquitectura activo-activo de Cassandra garantiza la continuidad del servicio desde el CPD disponible. Una vez recuperado el CPD caído, Cassandra sincroniza los nodos automáticamente.

---

## Requisitos a validar con el equipo de backup

Para asegurar el correcto funcionamiento de esta estrategia, el equipo de backup deberá validar los siguientes puntos antes de activar el proceso en producción:

| # | Requisito | Detalle |
|---|-----------|---------|
| 1 | Punto de montaje compartido | `/mnt/cohesity_pickup/` debe ser accesible desde cada nodo Cassandra (NFS u equivalente) |
| 2 | Frecuencia de recogida de Cohesity | Cohesity debe recoger los paquetes antes de que la purga local los elimine |
| 3 | Espacio de staging en nodos Cassandra | Espacio temporal en `/var/lib/cassandra/backup_staging/` para construir el paquete |
| 4 | Ancho de banda | Capacidad de red suficiente entre nodos y punto de montaje para los volúmenes esperados |
| 5 | Políticas de retención en Cohesity | 30 días para backups diarios y commit logs; 10 años para archivos semestrales |
| 6 | Prueba de restauración end-to-end | Validar en entorno de desarrollo que un backup generado es restaurable completamente |
| 7 | Alertas por fallo de backup | Configurar notificación cuando algún script de backup finalice con error |

---

## Planificación de ejecución (cron)

| Tarea | Horario | Entornos |
|-------|---------|----------|
| Exportación de esquema CQL | 00:50 diario | Todos |
| Snapshot diario (datos + esquema) | 01:00 diario | Todos |
| Backup de commit logs | Cada hora | Todos |
| Archivo semestral | 1 ene y 1 jul – 02:00 | Solo producción (CPD primario) |

---

## Resumen RPO / RTO

| Escenario | RPO | RTO estimado |
|-----------|-----|--------------|
| Error lógico con recuperación a punto en el tiempo | ≈ 1 hora | 2 – 4 horas |
| Error lógico con restauración de snapshot diario | ≈ 24 horas | 1 – 2 horas |
| Caída de un CPD (arquitectura activo-activo) | 0 | 0 (sin restauración) |
| Pérdida total del clúster | ≈ 1 hora | 4 – 8 horas |
