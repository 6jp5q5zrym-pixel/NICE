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

## 6. Estructura de Carpetas en el Servidor IFM (Windows)

```
C:\Actimize\IFM\BulkPayments\        ← Root folder
├── XML\
│   ├── Input\                        ← Depositar aquí los ficheros .xml
│   ├── Intermediate\                 ← IFM mueve el fichero aquí durante el proceso
│   └── Processed\                    ← IFM mueve el fichero aquí al terminar
├── NACHA\
│   ├── Input\
│   ├── Intermediate\
│   └── Processed\
└── HybridNACHA\
    ├── Splitter\Input\               ← Solo si se usa el file splitter
    ├── Input\
    ├── Intermediate\
    └── Processed\
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
<AIS_instance_folder>\logs\access_logs\ff_bulk_access.log
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

## 15. Preguntas Pendientes de Confirmar con NICE/Implementador

1. **Esquema XSD**: ¿Tenemos acceso al `Interfaces/XSD/Bulk Payments Process/` de la instalación IFM? Necesitamos el XSD para generar XML válido.
2. **Master Feed Excel**: ¿Disponemos del fichero Excel con el mapeo de campos (columna `Element Name In Hierarchical Input`)?
3. **Volumen por bulk**: ¿Cuántas remesas diarias hay en PRO? ¿Pueden superarse 20K en un solo bulk?
4. **Instancias AIS**: ¿Hay múltiples instancias AIS en PRO? Si es así, necesitamos carpetas `Intermediate`/`Processed` separadas por instancia.
5. **Tipo de proceso**: ¿Usaremos el proceso solución `FF_bulkPaymentsXml` out-of-the-box o necesitaremos un proceso custom?
6. **Scheduler Windows**: ¿El proceso de generación del XML se dispara desde Windows Task Scheduler o hay un orquestador (Control-M, Autosys)?
