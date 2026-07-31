# NICE Actimize IFM-X — Bulk Payments: End-to-End de Remesas

## 1. Visión General del Flujo

```
Core Bancario
(Oracle / T-1)
      │
      │  Fichero XML (UTF-8, ASCII)
      ▼
┌─────────────────────────────────────────────────────────────┐
│              CARPETA DE ENTRADA (Input Folder)               │
│    C:\Actimize\IFM\BulkPayments\XML\Input\                   │
└─────────────────────┬───────────────────────────────────────┘
                      │  FF_bulkPaymentsFeedChannel
                      │  (AIS no-parse: transfiere el fichero sin parsearlo)
                      ▼
┌─────────────────────────────────────────────────────────────┐
│          CARPETA INTERMEDIA (Intermediate Folder)            │
│    C:\Actimize\IFM\BulkPayments\XML\Intermediate\            │
│    [fichero aquí mientras AIS lo procesa]                    │
└─────────────────────┬───────────────────────────────────────┘
                      │  Validación XSD + Parsing XML jerárquico
                      │  Evaluación por Logical Group → Bulk Payment → Entry
                      ▼
┌─────────────────────────────────────────────────────────────┐
│              MOTOR IFM-X (AIS + Policy Manager)              │
│  • Detección interna (reglas de fraude)                      │
│  • Scoring rules (nivel entry y bulk)                        │
│  • Policy Manager (nivel entry y bulk)                       │
│  • Sets de análisis (historial, risk sets, etc.)             │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ├──→  Alertas de fraude → ActOne (casos)
                      ▼
┌─────────────────────────────────────────────────────────────┐
│             CARPETA PROCESADA (Processed Folder)             │
│    C:\Actimize\IFM\BulkPayments\XML\Processed\               │
│    [fichero movido aquí al finalizar con éxito]              │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Restricciones Importantes del Interface

| Restricción | Detalle |
|-------------|---------|
| **Solo batches originados** | IFM **no** admite batches recibidos (non-originated). Para remesas: solo las que **origina** el banco |
| **Fuente obligatoria** | Únicamente `folder source` — no hay ingesta por API ni MQ para bulk |
| **Codificación** | UTF-8 obligatorio |
| **Caracteres** | Nombre de fichero y contenido: **solo ASCII** |
| **Nombre de fichero** | Se recomienda nombre único por fichero (incluir timestamp/secuencia) |
| **Formatos soportados** | XML · NACHA · Hybrid NACHA (Fiserv PRM/PEP+) — interfaces separadas |

> **Implicación para remesas:** Nuestro fichero batch de remesas exportado desde Core Banking debe ser XML (no el pipe-delimited `.dat` que se usa para SAM). El esquema XML lo define el fichero **Actimize Fraud IFM-X Internal Master Feed Excel** (pestaña *CB Bulk Payments Interface*) y los `.xsd` en `Interfaces/XSD/Bulk Payments Process/` de la instalación IFM.

---

## 3. Estructura Jerárquica del XML

El XML tiene **tres niveles anidados**:

```
Fichero XML
└── Logical Group 1          ← agrupa bulk payments relacionados (p.ej. por canal o tipo)
    ├── Bulk Payment 1       ← una remesa o lote de remesas con cabecera común
    │   ├── Entry 1          ← cada transferencia individual
    │   ├── Entry 2
    │   └── Entry N
    └── Bulk Payment P
        ├── Entry 1
        └── Entry M
└── Logical Group G
    └── Bulk Payment Q
        ├── Entry 1
        └── Entry T
```

### Mapeo conceptual para remesas

| Nivel XML | Equivalente en remesas | Campos clave |
|-----------|----------------------|--------------|
| **Logical Group** | Sesión de carga / entidad originadora | Fecha proceso, entidad bancaria, canal |
| **Bulk Payment** | Lote / fichero batch del Core Banking | Referencia lote, cuenta debitada, divisa, importe total |
| **Entry** | Remesa individual (1 transacción) | TRN_ID, UETR, importe, ordenante, beneficiario, Travel Rule fields |

### Campos opcionales (nodos que el cliente puede omitir)

IFM-X permite omitir los siguientes nodos del XML si no se dispone de los datos:

- HTTP Header / Mobile Device Data / Online Device Identifiers
- Online Session / Phone Session / Web Device
- Party Reference / User Reference / Custom Data
- Account Reference / Bulk Payment Metadata
- Trx Monitored Party Data / Reject Data
- Payee Account Reference / Payee Party Reference
- Transfer Transaction
- Trx Party Address / Trx Payee Party Data / Trx Payee Address
- Managed Payee

> **Para remesas:** Los nodos de dispositivo (Mobile, Online, Web) normalmente no aplican en transferencias SWIFT/SEPA batch. Sí son obligatorios los campos de Travel Rule (ordenante y beneficiario completos).

### Custom Fields

Existen campos personalizados en **tres niveles**:
- A nivel de **Logical Group**
- A nivel de **Bulk Payment**
- A nivel de **Entry**

El nombre de cada elemento sigue la columna `Element Name In Hierarchical Input for CB Bulk Payments` del Master Data Model.

---

## 4. Canal de Ingestión: `FF_bulkPaymentsFeedChannel`

```
Input: ruta completa del fichero (string)
         │
         │  AIS no-parse feature
         │  (el canal transfiere el fichero SIN parsearlo — el parsing
         │   ocurre dentro del proceso de evaluación, no en el canal)
         ▼
Output: UDT FF_bulkPaymentsIn
         ├── solutionSources (FF_bulkPaymentsChannelSolutionSources)
         │     └── [Solo se pueden crear file custom sources]
         └── fileSource (FF_fileSource)
               ├── filePath  : ruta completa al fichero
               └── sourceName: nombre de la fuente configurada
                               Ej: FF_FOLDER_evaluateBulkPaymentsXml_V1
```

**Punto clave:** El canal **no parsea** el XML. El parsing y validación XSD se realizan dentro del proceso de evaluación bulk payments. Esto permite al canal ser ligero y rápido.

---

## 5. Fuente XML Out-of-the-Box

La fuente predefinida para XML es `FF_FOLDER_evaluateBulkPaymentsXml_V1`.

### Configuración por defecto (`FF_bulkPaymentsProcessesConfig.xml`)

| Parámetro | Valor por defecto |
|-----------|------------------|
| Configuration id | `FF_bulkPaymentsXml` |
| Source name | `FF_FOLDER_evaluateBulkPaymentsXml_V1` |
| Input file mask | `*.xml` |
| Root folder | Tomado de `FF_bulkPaymentsProcessRootFolder` en `FF_environmentConfig.ini` |
| Input folder | `XML/Input` |
| Intermediate folder | `XML/Intermediate` |
| Processed folder | `XML/Processed` |
| Encoding | `UTF-8` |

### Configuración de la raíz (dos alternativas)

1. **Atributo `rootFolder`** en `BulkPaymentsProcessConfig` del XML de config (tiene **prioridad**)
2. **Parámetro `FF_bulkPaymentsProcessRootFolder`** en `FF_environmentConfig.ini`

---

## 6. Estructura de Carpetas en el Servidor IFM (Windows) — Rutas Reales

```
C:\Actimize\ais_server\Instances\Actimize_IFM_RT1\      ← Instancia AIS
│
├── AdditionalFiles\BulkPaymentProcess\                  ← Root folder bulk payments
│   └── XML\
│       ├── Input\        ← Depositar aquí los ficheros .xml generados por Core Banking
│       ├── Intermediate\ ← IFM mueve el fichero aquí mientras lo procesa
│       └── Processed\    ← IFM mueve el fichero aquí al terminar correctamente
│
├── FF_environmentConfig.ini           ← Hilos, parámetros de entorno IFM
├── FF_environmentConfigImpl.ini       ← Configuración custom del implementador
├── FF_applicationConfig.ini           ← Parámetros IFM (heap, bulk mode, response mode)
├── FF_bulkPaymentsProcessesConfig.xml ← Fuentes bulk (carpetas, encoding, source name)
├── ais_config.xml                     ← JVM de AIS (heap, GC, Akka)
├── ais_broker_config.xml              ← ActiveMQ broker (memory, store, temp limits)
└── logs\
    └── access_logs\
        └── ff_bulk_access.log         ← Métricas por bulk payment procesado
```

> **Regla de aislamiento (Huge Bulk Mode):** Si hay múltiples instancias AIS o procesos bulk con carpeta de input compartida, cada instancia/proceso debe tener sus propias carpetas `Intermediate` y `Processed` separadas.

---

## 7. Configuración de Hilos (Threads)

El rendimiento del proceso bulk payments se controla con paralelismo en cuatro niveles:

### Niveles de paralelismo

| Nivel | Parámetro `<process>` | Descripción |
|-------|-----------------------|-------------|
| **FolderSource** | `FolderSource` | Paralelismo a nivel de fichero (parsing) |
| **Bulk Payment** | `PaymentWorker` | Paralelismo a nivel de lote |
| **Entry (pre-process)** | `EntryWorker` | Paralelismo a nivel de entrada, pre-procesamiento |
| **Entry (detección)** | `EntryPolicyManagerWorker` | Paralelismo a nivel de entrada, detección + scoring + Policy Manager |

### Procesos solución (out-of-the-box)

Fichero: `FF_environmentConfig.ini`

```ini
FF_solutionBulkPaymentProcess_FF_bulkPaymentsXml_FolderSource_ConcurrentThreads=1
FF_solutionBulkPaymentProcess_FF_bulkPaymentsXml_PaymentWorker_ConcurrentThreads=1
FF_solutionBulkPaymentProcess_FF_bulkPaymentsXml_EntryWorker_ConcurrentThreads=1
FF_solutionBulkPaymentProcess_FF_bulkPaymentsXml_EntryPolicyManagerWorker_ConcurrentThreads=1
```

Por defecto todos en **1 hilo**. Ajustar según capacidad del servidor IFM.

### Procesos custom (implementador)

Fichero: `FF_environmentConfigImpl.ini`

```ini
FF_customBulkPaymentProcess_<identifier>_FolderSource_ConcurrentThreads=N
FF_customBulkPaymentProcess_<identifier>_PaymentWorker_ConcurrentThreads=N
FF_customBulkPaymentProcess_<identifier>_EntryWorker_ConcurrentThreads=N
FF_customBulkPaymentProcess_<identifier>_EntryPolicyManagerWorker_ConcurrentThreads=N
```

---

## 8. Configuración AIS para Bulk Payments

Fichero: `ais_config.xml` (en la carpeta de la instancia AIS)

### Configuración base (bulk payments estándar)

```xml
<!-- Java Max Heap Size -->
<Configuration_Entry Key="Java Max Heap Size (MB)">24000</Configuration_Entry>

<!-- JVM Settings: cambiar GC y desactivar logs Akka -->
<Configuration_Entry Key="Additional JVM Settings">
  -XX:+UseParallelGC
  ;-Dakka.actor.debug.receive=off
  ;-Dakka.stdout-loglevel=OFF
  ;-Dakka.loglevel=OFF
</Configuration_Entry>
```

> **Cambio crítico de GC:** Reemplazar `-XX:+UseConcMarkSweepGC` por `-XX:+UseParallelGC` para procesamiento batch de alto volumen.

---

## 9. Huge Bulk Mode (> 20.000 entradas por bulk)

### ¿Cuándo activarlo?

Si un solo Bulk Payment contiene **más de 20.000 entries** (remesas individuales).  
Se **recomienda activarlo en todos los entornos** que procesen bulk payments de alto volumen.

### Impacto en la detección (sets limitados)

Cuando está activo, IFM excluye las entries del bulk actual de ciertos sets para mejorar el rendimiento:

| Set afectado | Comportamiento en Huge Bulk Mode |
|--------------|----------------------------------|
| **Current Bulk Payment Entries Set** | Solo se rellena para el Policy Manager a nivel bulk. Vacío para: detección interna, scoring rules de entry y bulk, Policy Manager de entry |
| **Company High Risk Monetary Activity Set** | No incluye las entries del bulk actual en: scoring rules de entry y bulk, Policy Manager de entry |
| **Company Distinct High Risk Monetary Activity Set** | Igual que el anterior |
| **Alert Field Distribution Exit Point Set** | Los UDTs `currentBulkPaymentEntriesSet`, `bulkPaymentEntriesFinalActions` y `bulkPaymentEntriesTriggeredPolicyRules` quedan vacíos |

### Configuración AIS para Huge Bulk (`ais_config.xml`)

```xml
<!-- Heap máximo -->
<Configuration_Entry Key="Java Max Heap Size (MB)">150000</Configuration_Entry>

<!-- Habilitar consolidación de entidades recurrentes -->
<Configuration_Entry Key="Profiles Queue Listener - Consolidate Updates of Recurring Entities Enabled">1</Configuration_Entry>
```

### Configuración ActiveMQ (`ais_broker_config.xml`)

```xml
<!-- Memory limit por cola -->
<policyEntry queue=">" producerFlowControl="true" memoryLimit="20480mb">

<!-- Memory usage: usar % del heap JVM en lugar de valor fijo -->
<memoryUsage>
  <memoryUsage percentOfJvmHeap="70"/>
</memoryUsage>

<!-- Store usage -->
<storeUsage>
  <storeUsage limit="30 gb"/>
</storeUsage>

<!-- Temp usage -->
<tempUsage>
  <tempUsage limit="2 gb"/>
</tempUsage>
```

### Activar Huge Bulk Mode en IFM (`FF_applicationConfig.ini`)

```ini
FF_supportHugeBulksMode=TRUE
```

---

## 10. Checklist de Implementación para Remesas

### Fase 1 — Instalación y configuración base

- [ ] Verificar que IFM-X tiene instalado el módulo CB Bulk Payments
- [ ] Localizar `Interfaces/XSD/Bulk Payments Process/` en la instalación IFM → obtener el `.xsd` para XML
- [ ] Obtener el **Actimize Fraud IFM-X Internal Master Feed Excel** → pestaña *CB Bulk Payments Interface* y *Master Data Model*
- [ ] Crear la estructura de carpetas en el servidor IFM Windows:
  - `<root>\XML\Input\`
  - `<root>\XML\Intermediate\`
  - `<root>\XML\Processed\`
- [ ] Configurar `FF_bulkPaymentsProcessRootFolder` en `FF_environmentConfig.ini`
- [ ] Editar `ais_config.xml`: heap 24 GB, cambiar GC, desactivar logs Akka
- [ ] Reiniciar instancia AIS

### Fase 2 — Mapeo de datos

- [ ] Mapear campos del Core Banking (PAYMENTS.REMITTANCE_TXN) a los elementos XML del Master Feed
- [ ] Confirmar campos de Travel Rule obligatorios (ordenante + beneficiario según FATF R.16)
- [ ] Decidir qué nodos opcionales omitir (Mobile, Online, Web — normalmente no aplican en SWIFT/SEPA batch)
- [ ] Implementar generador de XML validado contra el `.xsd` de IFM

### Fase 3 — Ajuste de rendimiento

- [ ] Estimar volumen: ¿supera un Bulk Payment las 20.000 remesas?
  - **Sí** → activar `FF_supportHugeBulksMode=TRUE` + configurar AIS para huge bulk (heap 150 GB)
  - **No** → configuración base (heap 24 GB)
- [ ] Ajustar hilos en `FF_environmentConfig.ini` / `FF_environmentConfigImpl.ini` según CPUs del servidor IFM
- [ ] Considerar múltiples custom processes si hay ficheros de distinta prioridad o tamaño

### Fase 4 — Validación

- [ ] Enviar fichero XML de prueba (datos sintéticos DEV)
- [ ] Verificar que el fichero pasa validación XSD (AIS lo valida automáticamente)
- [ ] Verificar que el fichero se mueve de `Input` → `Intermediate` → `Processed`
- [ ] Verificar generación de alertas IFM en ActOne
- [ ] Medir latencia end-to-end (objetivo: < 4h para carga nocturna completa)

---

## 11. Sub-procesos del Bulk Payments Process

El proceso de Commercial Banking Fraud bulk payments se compone de **cinco sub-procesos**:

| Sub-proceso | Tipo | Descripción |
|-------------|------|-------------|
| **NACHA File Splitter** | Opcional | Divide ficheros de entrada en bulks individuales antes del proceso principal. Solo para NACHA/Hybrid NACHA |
| **Main Loader** | Ejecución puntual | Plan de ejecución CB bulk payments loader basado en AIS folder source |
| **Bulk Payments Service** | Proceso infinito | Gestiona los bulk payments (nivel lote) |
| **Entries Service** | Proceso infinito | Gestiona las entries (nivel remesa individual) |
| **Entry Policy Manager Service** | Proceso infinito | Gestiona el Policy Manager a nivel de entry |

> **Importante:** El límite máximo de transacciones en un único fichero XML es **999.999 entries**.

### Arrancar el proceso (`FF_bulkPaymentsProcess`)

Ubicación en Visual Modeler: `Batch Processes/BulkPayments/` → paquete *Fraud Framework - Executables*

```
Execution Plan: FF_bulkPaymentsProcess
Argumento: configurationId = <id del proceso en FF_bulkPaymentsProcessesConfig.xml>
           Ejemplo: FF_bulkPaymentsXml
           Para NACHA file splitter: FF_bulkPaymentsHybridNacha
```

**Restricción:** No se pueden ejecutar simultáneamente dos procesos con el mismo `configurationId`. Para paralelismo se deben definir múltiples custom processes con IDs distintos en `FF_bulkPaymentsProcessesConfig.xml`.

### ADL Log Data Queue Listener

Los ADLs (Audit Data Logs) del proceso bulk payments se escriben de forma **asíncrona** a través de Apache ActiveMQ.

- **Cola AMQ:** `BulkPaymentsADLLogData`
- **Execution plan:** `FF_startBulkPaymentsADLLogQueueListener`
  - Ubicación: `Queue/` → paquete *Fraud Framework – Executables*
  - Sin argumentos
- **Un solo listener** sirve para todos los procesos bulk payments simultáneos
- Solo es necesario arrancarlo si se han habilitado ADLs en alguno de los procesos

---

## 12. Exit Points de Integración y Detección

### 12.1 Entry Policy Manager Exit Point

**Flujo:** `FF_bulkPaymentEntryDataIntegrationExitPoint`  
**Ubicación:** `Fraud Framework – Customization/Data Integration/Incoming Data Integration/Incoming Data Integration Exit Points/`

#### Entrada: `FF_bulkPaymentEntryPolicyManagerExitPointIn`

| Campo | Tipo | Descripción |
|-------|------|-------------|
| `masterFeed` (FF_masterFeed) | UDT | Campos cliente e implementación de la entry actual — ver columna *CB Bulk Payment – Entry* en Master Data Model |
| `masterFeedEnrichments` (FF_masterFeedEnrichments) | UDT | Campos calculados de la entry actual |
| `bulkPaymentMasterFeed` (FF_masterFeed) | UDT | Campos cliente del bulk payment actual — ver columna *CB Bulk Payment - Payment* en Master Data Model |
| `bulkPaymentMasterFeedEnrichments` (FF_masterFeedEnrichments) | UDT | Campos calculados del bulk payment actual |
| `actionRulesResults` (FF_actionRulesResults) | UDT | Resultados del Bulk Payment Entry Policy Manager |
| → `FinalActions` | Set | Acciones resultado tras resolución de conflictos: `Name`, `Value`, `OriginalValue` |
| → `Triggered Rules` | Set | Reglas disparadas: `RuleIdentifier`, `RuleName`, `Actions` (set: `Name`, `Value`) |
| `scoringRulesResults` (FF_scoringRulesResults) | UDT | Resultados de scoring rules de la entry |
| → `Results` | Set | Por cada rule set: `RuleSetName`, `DisplayName`, `RuleSetScore` |
| → `TriggeredRules` | Set | Reglas disparadas: `Name`, `DisplayName`, `Tag`, `Score`, `ScoreDescription` |

#### Salida: `FF_bulkPaymentEntryPolicyManagerExitPointOut`

UDT vacío interno — el exit point recibe los resultados pero no requiere campos de salida propios.

### 12.2 Data Integration Exit Point (Entries)

**Entrada:** `FF_bulkPaymentEntryDataIntegrationExitPointIn`

Contiene `solutionSources` (FF_bulkPaymentEntrySolutionSources) con todas las fuentes de datos disponibles para enriquecer los datos de la entry antes de la evaluación.

> El Master Data Model (pestaña *Master Data Model* del IFM Internal Master Feed Excel) es la referencia definitiva para los campos disponibles en `masterFeed` y `masterFeedEnrichments` en cada nivel (entry y bulk payment).

---

## 13. Logging de Errores

### Tres niveles de log independientes

IFM mantiene **tres logs diferenciados** para bulk payments en los logs de proceso AIS:

| Log | Contenido |
|-----|-----------|
| **Entry log** | Errores y warnings a nivel de remesa individual |
| **Payment log** | Errores y warnings a nivel de bulk payment (lote) |
| **File log** | Errores a nivel de fichero completo |

**Propagación de errores hacia arriba:** Un error en una entry genera entradas en los tres logs (entry + payment + file). Un error en un bulk payment genera entradas en payment + file. Los warnings solo se escriben en el nivel en que ocurren.

### Parámetro de control: `FF_maxNumberOfLoggedChildErrors`

Fichero: `FF_applicationConfig.ini`

Limita cuántos errores de nivel hijo se incluyen en el mensaje de error del nivel padre (referenciado como `X` en la lógica siguiente).

### Lógica de logging por nivel

**Entry Level:**
- Entry válida → 1 mensaje WARNING con lista de todos los warnings
- Entry inválida → 1 mensaje ERROR con todos los errores + warnings

**Bulk Payment Level:**
- Bulk válido → 1 mensaje WARNING con warnings del bulk
- Bulk inválido → 1 mensaje ERROR con: todos los errores del bulk (sin límite) + lista de hasta `X` entries inválidas, cada una con hasta `X` errores/warnings (errores tienen prioridad)

**File Level:**
- Sin mensajes WARNING
- Si hay bulk payments inválidos → 1 mensaje ERROR con lista de hasta `X` bulk payments inválidos, cada uno con hasta `X` entries inválidas y sus errores/warnings

### Códigos de error

| Código | Nivel | Categoría | Causa |
|--------|-------|-----------|-------|
| **1100** | Bulk Payment | BulkPayment | % de entries válidas por debajo del mínimo configurado en `FF_batchBulkPaymentMinimumPercentageOfValidEntries` |
| **1201** | Entry Pre-Processing | BulkPaymentEntry | Error en pre-procesamiento de entry (data integration, validación, enrichments) |
| **1202** | Bulk Payment | BulkPayment | Error durante procesamiento del bulk — invalida el bulk completo |
| **1203** | Bulk Payment File | BulkPaymentFile | Error al leer/parsear el fichero, o uno o más bulk payments fallaron |
| **1204** | Entry Detection | BulkPaymentEntryDetection | Error en detección interna o Policy Manager de entry — invalida el bulk completo |
| **1210** | Init Error | BulkPaymentInitError | Error al arrancar el proceso: `configurationId` inválido o carpetas mal configuradas |

### Ejemplo de mensaje de error (entry con warnings)

```
[Flow: FF_bulkPaymentsEntryWorker(1)] BulkPaymentEntry #901201 - An Entry
Validation error occurred for entry:
  entryId=[Entry1_TransactionKey],
  transactionKey=[Entry1_TransactionKey],
  transactionNormalizedDateTime=[2009-12-01 22:59:01],
  transactionId=[TransactionId],
  parentTransactionKey=[77ba165c-ac6f-4562-9549-7517187b5ef5],
  actimizeParentVersionIdentity=[BP_TransactionKey2pDP954HlTCe],
  actimizeTransactionKey=[3a6d8443-821a-4b64-a916-e5b6d2077349]
within bulk payment:
  paymentId=[BP_TransactionKey],
  transactionKey=[BP_TransactionKey],
  transactionNormalizedDateTime=[2009-12-01 22:59:01]
within file:
  actimizeInputFileName=[validXml_onlyEntryWarnings.xml],
  logicalInputFileCreationDateTime=[2009-12-01 22:59:01],
  logicalFileSequenceId=[LogicalFileSequenceId]

There were 2 warnings:
  Warning: Field: trxFIRoutingType. Value not specified for mandatory field. (#1033).
  Warning: Field: trxFIRoutingNumber. Value not specified for mandatory field. (#1034).
```

> **Para remesas:** Los campos `trxFIRoutingType` y `trxFIRoutingNumber` corresponden a datos del banco receptor (BIC/SWIFT routing). Deben mapearse desde `RECEIVER_BIC` en Core Banking.

---

## 14. Access Logs de Bulk Payments

Los access logs registran métricas de rendimiento y estado de **cada bulk payment procesado** (no por entry ni por fichero).

### Ubicación

```
C:\Actimize\ais_server\Instances\Actimize_IFM_RT1\logs\access_logs\ff_bulk_access.log
```

Rotación automática: nuevo fichero al superar **20 MB**, nombrado `ff_bulk_access.log1`, `ff_bulk_access.log2`, etc. IFM no elimina los ficheros automáticamente — gestión de retención a cargo del equipo de operaciones.

### Campos del access log (TSV con cabecera)

| Campo | Descripción |
|-------|-------------|
| `fileName` | Nombre del fichero XML de entrada |
| `bulkId` | Identificador del bulk payment dentro del fichero |
| `startProcessingTime` | Timestamp de inicio de procesamiento |
| `timeUntilResponseMillis` | Tiempo hasta recibir respuesta (ms) |
| `totalProcessingTimeMillis` | Tiempo total de procesamiento del bulk (ms) |
| `status` | Estado del procesamiento (OK / ERROR) |
| `uniquePEPFileID` | Solo Hybrid NACHA |
| `pepPointName` | Solo Hybrid NACHA |
| `uniquePEPBatchID` | Solo Hybrid NACHA |
| `noOfEntries` | Solo Hybrid NACHA y NACHA — número de entries del bulk |
| `responseFileOnS3Status` | Siempre `skipped` en On-Premise |

> **Uso operativo:** El access log es la primera herramienta para diagnosticar rendimiento. Si `totalProcessingTimeMillis` de algún bulk es anómalamente alto, revisar el número de entries y considerar activar Huge Bulk Mode o aumentar hilos en `EntryWorker`/`EntryPolicyManagerWorker`.

---

## 15. Flujo de Respuesta — End-to-End Completo

Con la respuesta se cierra el ciclo. El flujo completo queda así:

```
Core Bancario
      │ XML file
      ▼
Input Folder ──→ AIS (no-parse) ──→ Intermediate Folder
                                           │
                              Validación XSD + Parsing
                                           │
                              ┌────────────▼────────────────────────┐
                              │    MOTOR IFM-X (por cada Bulk Payment)    │
                              │                                      │
                              │  Entries Service                     │
                              │    └─ Entry Data Integration EP      │
                              │    └─ Internal Detection             │
                              │    └─ Entry Scoring Rules            │
                              │    └─ Entry Policy Manager EP        │
                              │                                      │
                              │  Bulk Payment Service                │
                              │    └─ Bulk Scoring Rules             │
                              │    └─ Bulk Policy Manager            │
                              └────────────┬────────────────────────┘
                                           │
                              ┌────────────▼────────────────────────┐
                              │  BUILD RESPONSE EXIT POINT           │
                              │  FF_bulkPaymentBuildResponseMessage  │
                              │  ExitPoint  (SÍNCRONO siempre)       │
                              │                                      │
                              │  Construye el mensaje de respuesta   │
                              │  con scores, risk levels, acciones   │
                              └──┬─────────────────────┬────────────┘
                                 │ GUARDA               │ GUARDA
                                 ▼ (síncrono)           ▼ (asíncrono)
                        FF_TRX_CALC_DATA          ARD_RESULT (IDB)
                        (app database)            (para consulta posterior)
                                 │
                              ┌──▼──────────────────────────────────┐
                              │  NOTIFY CLIENT EXIT POINT            │
                              │  FF_bulkPaymentNotifyResponseMessage │
                              │  ExitPoint  (sync por defecto)       │
                              │                                      │
                              │  Notifica al sistema cliente         │
                              │  (WS call, AMQ message, fichero...)  │
                              └─────────────────────────────────────┘
                                           │
                              ┌────────────▼────────────────────────┐
                              │         Processed Folder             │
                              └─────────────────────────────────────┘
```

### Dos exit points, dos responsabilidades distintas

| Exit Point | Cuándo se llama | Para qué |
|-----------|----------------|----------|
| `FF_bulkPaymentBuildResponseMessageExitPoint` | **Antes** de guardar en BD — síncrono siempre | Construir el mensaje de respuesta a partir de scores, acciones y resultados |
| `FF_bulkPaymentNotifyResponseMessageExitPoint` | **Después** de guardar — sync o async según config | Enviar/notificar la respuesta al sistema cliente |

**Respuesta por bulk:** Hay una respuesta independiente por cada bulk payment dentro del fichero, no una respuesta por fichero.

**Persistencia de la respuesta** (por si el bulk se reenvía o el cliente la consulta más tarde):
- `FF_TRX_CALC_DATA` (application database) — guardado **síncrono**
- `ARD_RESULT` (IDB) — guardado **asíncrono**

---

## 16. Build Response Exit Point

**Ubicación:** `Fraud Framework - Customization/Data Integration/Outgoing Data Integration/Outgoing Data Integration Exit Points/`

### Entrada: `FF_bulkPaymentBuildResponseMessageExitPointIn`

#### Datos del Bulk Payment

| Campo | Tipo | Descripción |
|-------|------|-------------|
| `bulkPayment` (FF_bulkPaymentResponseData) | UDT | Contenedor de datos de respuesta del bulk |
| → `validEntriesCount` | Integer | Nº de entries válidas en el bulk |
| → `invalidEntriesCount` | Integer | Nº de entries inválidas |
| → `totalNumberOfBulkPaymentEntries` | Integer | Total de entries en el bulk |
| `bulkPaymentFeed` (FF_enrichedMasterFeed) | UDT | Campos completos del bulk (cliente + implementación + calculados) |
| `bulkPaymentResults` (FF_bulkPaymentResults) | UDT | Resultados del bulk |
| → `actimizeAnalyticsScore` | Double | **Score máximo asignado a cualquier entry individual del bulk** |
| → `userAnalyticsScore` | Double | Score de user analytics — actualmente `null` |
| → `isAlertGenerated` | Boolean | Si se generó alguna alerta de bulk payment |
| → `actimizeAnalyticsResults` | UDT | Issues de analytics — actualmente `null` |
| → `actionRulesResults` (FF_actionRulesResults) | UDT | Resultados del Policy Manager de detección |
| → → `FinalActions` | Set | `Name`, `Value`, `OriginalValue` — acciones tras resolución de conflictos |
| → → `TriggeredRules` | Set | Reglas disparadas desde user-defined analytics |
| → `scoringRulesResults` (FF_scoringRulesResults) | UDT | Scoring rules disparadas y sus scores |
| → `analyticsVariables` | UDT | Variables de analytics — actualmente `null` |

#### Datos de cada Entry válida (`Entries` SET)

| Campo | Tipo | Descripción |
|-------|------|-------------|
| `entry` (FF_entryResponseData) | UDT | Datos de respuesta de cada entry válida |
| → `bulkPaymentEntryFeed` (FF_enrichedMasterFeed) | UDT | Campos completos de la entry (cliente + implementación + calculados) |
| → `entryResults` (FF_entryResults) | UDT | Resultados de la entry |
| → → `actimizeTransactionRiskScore` | Boolean | Score de analytics Actimize de la entry |
| → → `userAnalyticsScore` | Double | Score user analytics — actualmente `null` |
| → → `riskLevel` | Integer | Nivel de riesgo (ver tabla abajo) |
| → → `actimizeAnalyticsResults` | UDT | Issues de analytics de la entry |
| → → `actionRulesResults` | Set | Policy Manager de la entry: `FinalActions`, `TriggeredRules` |
| → → `scoringRulesResults` | Set | Scoring rules de la entry |
| → → `analyticsVariables` | UDT | Variables de analytics — actualmente `null` |

#### Tabla de Risk Level por entry

| Valor | Nivel de riesgo |
|-------|----------------|
| `1` | Very High |
| `2` | High |
| `3` | Medium |
| `4` | Low |
| `5` | Very Low |
| `6` | Unknown |

> **Para remesas:** El `riskLevel` de cada entry es el campo central para decidir si una remesa pasa, se bloquea o va a revisión manual en ActOne. Combinarlo con `actimizeTransactionRiskScore` y las `FinalActions` del Policy Manager.

### Salida

El exit point construye la respuesta que IFM persistirá en BD. La respuesta se almacena como string en `cs1`/`cs2`/`responseMessage` y es lo que recibe el Notify exit point.

---

## 17. Notify Client Exit Point

### Entrada: `FF_bulkPaymentNotifyResponseMessageExitPointIn`

| Campo | Tipo | Descripción |
|-------|------|-------------|
| `isResend` | Boolean | `true` si la respuesta es un reenvío (bulk ya procesado anteriormente) |
| `BulkPaymentResponseMessage` (FF_bulkPaymentResponseMessage) | UDT | El mensaje de respuesta completo |
| → `cs1` | Char | String de respuesta construido en el Build Response exit point |
| → `cs2` | Char | String de respuesta construido en el Build Response exit point |
| → `responseMessage` | Char | El mensaje de respuesta tal como se guardó en BD |

**Sin salida** — este exit point no tiene output.

### Sync vs. Async — decisión de implementación

| Modo | Cuándo usarlo | Comportamiento ante fallo |
|------|--------------|--------------------------|
| **sync** (defecto) | Implementación simple / notificación local | IFM logea el error y continúa — el bulk se marca como completado igualmente |
| **async** | Llamada a WS externo / operación lenta / propensa a fallos | AMQ reintenta `FF_amqBPNotifyMessageNumberOfMessageHandlingRetries` veces antes de descartar y loguear |

> **Riesgo async:** El bulk puede haberse procesado correctamente pero la notificación llega tarde por backlog en la cola AMQ.

---

## 18. Configuración de la Respuesta

### `FF_applicationConfig.ini` (en cada instancia AIS)

| Parámetro | Default | Descripción |
|-----------|---------|-------------|
| `FF_batchBulkPaymentResponseMessageMode` | `sync` | Modo de ejecución del Notify Client exit point: `sync` \| `async` |
| `FF_amqBPNotifyMessageNumberOfMessageHandlingRetries` | `3` | (Solo async) Reintentos AMQ antes de descartar el mensaje |
| `FF_amqBPNotifyMessageConsumerNumOfMessagesUntilAutoCommit` | `1` | (Solo async) Mensajes por commit en el consumer AMQ |
| `FF_amqBPNotifyMessageConsumerNumOfMessagesToSendToMsgHandler` | `1` | (Solo async) Mensajes enviados al handler por lote |

### `FF_environmentConfig.ini` (en cada instancia AIS)

| Parámetro | Default | Descripción |
|-----------|---------|-------------|
| `FF_AMQ_BulkPaymentNotifyResponse_NumberOfConcurrentThreads` | `1` | (Solo async) Hilos del listener AMQ para la respuesta |

### Arrancar el listener de respuesta (solo si modo async)

```
Execution Plan: FF_startBulkPaymentNotifyResponseQueueListener
Ubicación: Batch Processes/BulkPayments/ — paquete Fraud Framework - Executables
```

---

## 19. Estructura XML del Fichero de Entrada — Mapeo Completo

El XML sigue una jerarquía de **4 niveles**. Cada nivel tiene sus propios nodos con tipos IFM específicos.

### Opciones de validación XSD

| Opción | Ventaja | Inconveniente |
|--------|---------|---------------|
| **Con validación XSD** (recomendado) | Detecta errores estructurales antes del parsing | Los campos deben ir en el orden del XSD |
| **Sin validación XSD** | Campos dentro de un elemento en cualquier orden | Un error estructural no se detecta y el parser falla sin mensaje claro |

> Para implementación inicial: **activar validación XSD**. Facilita el debugging durante el desarrollo.

---

### Nivel 1: Logical Group

Agrupa uno o más Bulk Payments. Campos opcionales para remesas batch (sin canal digital).

```xml
<LogicalGroup>
    <!-- Opcionales / no aplican en remesas SWIFT/SEPA batch -->
    <HTTPHeader>...</HTTPHeader>                          <!-- IFMHTTPHeaderTypeV2 -->
    <MobileDeviceData>...</MobileDeviceData>              <!-- IFMMobileDeviceType -->
    <OnlineDeviceIdentifiers>...</OnlineDeviceIdentifiers><!-- IFMOnlineDeviceIdentifiersType -->
    <CalculatedOnlineDeviceIdentifiers>...</CalculatedOnlineDeviceIdentifiers>
    <OnlineSession>...</OnlineSession>                    <!-- IFMOnlineSessionTypeV2 -->
    <PhoneSession>...</PhoneSession>                      <!-- IFMPhoneSessionType -->
    <WebDevice>...</WebDevice>                            <!-- IFMWebDeviceType -->

    <!-- PartyReference: datos del cliente ordenante a nivel de sesión -->
    <PartyReference>                                      <!-- IFMPartyReferenceType -->
        <PartyData>...</PartyData>                        <!-- IFMPartyDataType -->
        <AccountOwnershipData>...</AccountOwnershipData>  <!-- IFMAccountOwnershipType -->
        <AddressData>...</AddressData>                    <!-- IFMAddressTypeV2 -->
        <ContactData>...</ContactData>                    <!-- IFMContactReferenceType -->
        <ReferenceUpdateDates>...</ReferenceUpdateDates>  <!-- IFMReferenceUpdateDatesType -->
    </PartyReference>

    <!-- UserReference: datos del usuario que inicia la operación -->
    <UserReference>                                       <!-- IFMUserReferenceType -->
        <AddressData>...</AddressData>
        <ContactData>...</ContactData>
        <ReferenceUpdateDates>...</ReferenceUpdateDates>
    </UserReference>

    <CustomData>...</CustomData>                          <!-- IFMCustomDataType -->

    <!-- Uno o más BulkPayment -->
    <BulkPayment>...</BulkPayment>
</LogicalGroup>
```

**Para remesas SWIFT/SEPA batch:** Omitir todos los nodos de dispositivo (HTTP, Mobile, Online, Web, Phone). Pueden ser útiles `PartyReference` (datos KYC del ordenante) y `CustomData` (campos propietarios).

---

### Nivel 2: BulkPayment

Representa un lote de remesas (equivale a un batch del Core Banking).

```xml
<BulkPayment>
    <!-- Datos base del lote -->
    <BaseTransactionA>...</BaseTransactionA>              <!-- IFMBaseTransactionAType -->
    <BaseTransactionC>...</BaseTransactionC>              <!-- IFMBaseTransactionCType -->
    <MonetaryTransactionA>...</MonetaryTransactionA>      <!-- IFMMonetaryTransactionAType -->

    <!-- Cuenta debitada (cuenta del banco/entidad que origina el lote) -->
    <AccountReference>                                    
        <AccountData>...</AccountData>                    <!-- IFMAccountReferenceType -->
        <AddressData>...</AddressData>                    <!-- no usada por analytics -->
        <ContactData>...</ContactData>                    <!-- no usada por analytics -->
        <ReferenceUpdateDates>...</ReferenceUpdateDates>  <!-- no usada por analytics -->
        <AccountPartyRelationData>...</AccountPartyRelationData> <!-- IFMPartyRelationReferenceType -->
    </AccountReference>

    <!-- Metadatos del lote (fecha proceso, secuencia, etc.) -->
    <BulkPaymentMetadata>...</BulkPaymentMetadata>        <!-- IFMBulkPaymentMetadataType -->

    <!-- Parte monitorizadda: el ordenante del lote -->
    <TrxMonitoredParty>
        <TrxPartyData>...</TrxPartyData>                  <!-- IFMTrxPartyDataType -->
    </TrxMonitoredParty>

    <RejectData>...</RejectData>                          <!-- IFMRejectDataTypeV2 -->
    <CustomData>...</CustomData>                          <!-- IFMCustomDataType -->

    <!-- Una o más Entry -->
    <Entry>...</Entry>
</BulkPayment>
```

**Campos clave para remesas a nivel BulkPayment:**
- `BaseTransactionA` → ID del lote, timestamp, referencia
- `MonetaryTransactionA` → importe total del lote, divisa
- `AccountReference/AccountData` → cuenta de la entidad originadora (IBAN o cuenta nostro)
- `BulkPaymentMetadata` → fecha de proceso, secuencia del fichero
- `TrxMonitoredParty/TrxPartyData` → datos del cliente ordenante (nombre, ID, CIF interno)

---

### Nivel 3: Entry

Representa **una remesa individual**. Es el nivel donde IFM aplica la detección de fraude por transacción.

```xml
<Entry>
    <!-- Identificación de la transacción -->
    <BaseTransactionB>...</BaseTransactionB>              <!-- IFMBaseTransactionBType -->
    <BaseTransactionC>...</BaseTransactionC>              <!-- IFMBaseTransactionCType -->
    <MonetaryTransactionB>...</MonetaryTransactionB>      <!-- IFMMonetaryTransactionBType -->

    <!-- Cuenta ordenante (IBAN del cliente) -->
    <AccountReference>
        <AccountData>...</AccountData>                    <!-- IFMAccountReferenceType -->
        <AddressData>...</AddressData>                    <!-- no usada por analytics -->
        <ContactData>...</ContactData>                    <!-- no usada por analytics -->
        <ReferenceUpdateDates>...</ReferenceUpdateDates>  <!-- no usada por analytics -->
        <AccountPartyRelationData>...</AccountPartyRelationData>
    </AccountReference>

    <!-- Importe de la remesa -->
    <Amount>...</Amount>                                  <!-- IFMAmountTypeV2 -->

    <!-- Cuenta beneficiaria -->
    <PayeeAccountReference>
        <AccountData>...</AccountData>                    <!-- IFMAccountReferenceType -->
        <AddressData>...</AddressData>                    <!-- IFMAddressTypeV2 -->
        <ContactData>...</ContactData>
        <ReferenceUpdateDates>...</ReferenceUpdateDates>
        <AccountPartyRelationData>...</AccountPartyRelationData>
    </PayeeAccountReference>

    <!-- Payee gestionado (beneficiario registrado previamente) -->
    <ManagedPayee>...</ManagedPayee>                      <!-- IFMManagedPayeeType -->

    <!-- Datos completos del beneficiario (Travel Rule) -->
    <PayeePartyReference>                                 <!-- IFMPartyReferenceType -->
        <PartyData>...</PartyData>                        <!-- IFMPartyDataType -->
        <AccountOwnershipData>...</AccountOwnershipData>
        <AddressData>...</AddressData>                    <!-- IFMAddressTypeV2 -->
        <ContactData>...</ContactData>
        <ReferenceUpdateDates>...</ReferenceUpdateDates>
    </PayeePartyReference>

    <!-- Detalles de la transferencia (BIC, tipo pago, concepto) -->
    <TransferTransaction>...</TransferTransaction>        <!-- IFMTransferTransactionTypeV2 -->

    <!-- Cuenta monitorizadda del ordenante a nivel transacción -->
    <TrxMonitoredAccount>
        <TrxAccountData>...</TrxAccountData>              <!-- IFMTrxAccountDataType -->
    </TrxMonitoredAccount>

    <!-- Dirección del ordenante (Travel Rule) -->
    <TrxPartyAddress>
        <AddressData>...</AddressData>                    <!-- IFMAddressTypeV2 -->
    </TrxPartyAddress>

    <!-- Cuenta beneficiaria a nivel transacción -->
    <TrxPayeeAccount>
        <TrxAccountData>...</TrxAccountData>              <!-- IFMTrxAccountDataType -->
    </TrxPayeeAccount>

    <!-- Datos del beneficiario a nivel transacción -->
    <TrxPayeeParty>
        <TrxPartyData>...</TrxPartyData>                  <!-- IFMTrxPartyDataType -->
    </TrxPayeeParty>

    <!-- Dirección del beneficiario (Travel Rule) -->
    <TrxPayeeAddress>
        <AddressData>...</AddressData>                    <!-- IFMAddressTypeV2 -->
    </TrxPayeeAddress>

    <CustomData>...</CustomData>                          <!-- IFMCustomDataType -->
</Entry>
```

---

### Mapeo orientativo: Core Banking → XML IFM (Entry)

| Campo Core Banking (REMITTANCE_TXN / CUSTOMER) | Nodo XML IFM | Business Section |
|------------------------------------------------|-------------|-----------------|
| `r.TRN_ID` | `BaseTransactionB` | Base Transaction B |
| `r.UETR` | `BaseTransactionB` | Base Transaction B |
| `r.VALUE_DATE` / `r.PROCESS_DT` | `BaseTransactionB` | Base Transaction B |
| `r.AMOUNT` / `r.CURRENCY` | `Amount` | Amount |
| `r.EQUIV_EUR_AMOUNT` | `Amount` | Amount |
| `r.FX_RATE` | `MonetaryTransactionB` | Monetary Transaction B |
| `c.ACCOUNT_IBAN` | `AccountReference/AccountData` | Account Reference |
| `c.FULL_NAME` | `TrxMonitoredParty/TrxPartyData` (bulk) | Trx Monitored Party Data |
| `c.COUNTRY_CODE` / `c.ADDRESS` | `TrxPartyAddress/AddressData` | Trx Party Address |
| `c.ID_TYPE` / `c.ID_NUMBER` | `TrxMonitoredParty/TrxPartyData` | Trx Monitored Party Data |
| `c.INTERNAL_CIF` | `TrxMonitoredParty/TrxPartyData` | Trx Monitored Party Data |
| `r.BENEFICIARY_NAME` | `PayeePartyReference/PartyData` | Payee Party Reference |
| `r.BENEFICIARY_ACCOUNT` | `PayeeAccountReference/AccountData` | Payee Account Reference |
| `r.RECEIVER_BIC` | `TransferTransaction` | Transfer Transaction |
| `r.RECEIVER_COUNTRY` / `r.RECEIVER_ADDRESS` | `TrxPayeeAddress/AddressData` | Trx Payee Address |
| `r.INTERMEDIARY_BIC` | `TransferTransaction` | Transfer Transaction |
| `r.TXN_TYPE` / `r.PURPOSE_CODE` / `r.PAYMENT_METHOD` | `BaseTransactionB` / `MonetaryTransactionB` | Base / Monetary Transaction B |
| `r.REMITTANCE_INFO` | `TransferTransaction` | Transfer Transaction |
| `r.CHARGE_TYPE` | `MonetaryTransactionB` | Monetary Transaction B |
| `r.SENDER_BIC` | `TransferTransaction` | Transfer Transaction |

> **Pendiente confirmar con Master Data Model:** Los campos concretos dentro de cada tipo IFM (p.ej. cómo se llama el campo `TRN_ID` dentro de `IFMBaseTransactionBType`). Con la pestaña Master Data Model se puede completar esta tabla con los nombres exactos de elemento XML.

---

### Notas importantes del interfaz

1. `CustomData` aparece en **3 niveles**: Logical Group, BulkPayment y Entry
2. `BaseTransactionC` aparece en **2 niveles**: BulkPayment y Entry
3. `AccountReference` aparece en **2 niveles**: BulkPayment y Entry
4. Los nodos `AccountReference/AddressData`, `AccountReference/ContactData` y `AccountReference/ReferenceUpdateDates` **no son usados por analytics** en el proceso Bulk Payments

---

## 20. Preguntas Pendientes de Confirmar con NICE/Implementador

1. **Esquema XSD**: ¿Tenemos acceso al `Interfaces/XSD/Bulk Payments Process/` de la instalación IFM? Necesitamos el XSD para generar XML válido.
2. **Master Feed Excel**: ¿Disponemos del fichero Excel con el mapeo de campos (columna `Element Name In Hierarchical Input`)?
3. **Volumen por bulk**: ¿Cuántas remesas diarias hay en PRO? ¿Pueden superarse 20K en un solo bulk?
4. **Instancias AIS**: ¿Hay múltiples instancias AIS en PRO? Si es así, necesitamos carpetas `Intermediate`/`Processed` separadas por instancia.
5. **Tipo de proceso**: ¿Usaremos el proceso solución `FF_bulkPaymentsXml` out-of-the-box o necesitaremos un proceso custom?
6. **Scheduler Windows**: ¿El proceso de generación del XML se dispara desde Windows Task Scheduler o hay un orquestador (Control-M, Autosys)?
