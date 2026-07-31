# IFM-X Bulk Payments — Opciones de Respuesta del Canal

**Versión:** 1.0  
**Fecha:** 2026-07-31  
**Scope:** NICE Actimize IFM-X, módulo Remesas (BulkPayments)

---

## Índice

1. [Formato del mensaje de respuesta](#1-formato-del-mensaje-de-respuesta)  
2. [Qué implementar en Visual Modeler](#2-qué-implementar-en-visual-modeler)  
3. [Opción A — IBM MQ](#3-opción-a--ibm-mq)  
4. [Opción B — REST](#4-opción-b--rest)  
5. [Opción C — Fichero](#5-opción-c--fichero)  
6. [Comparativa y recomendación](#6-comparativa-y-recomendación)  
7. [Plan de pruebas para cada opción](#7-plan-de-pruebas-para-cada-opción)

---

## 1. Formato del mensaje de respuesta

### 1.1 Schema

El mensaje de respuesta sigue el schema definido en `schemas/remesas/ifm-bulk-response-v1.json`. A continuación se describe la estructura de alto nivel:

```
{
  schemaVersion: "1.0"
  header: {
    batchId, bulkTransactionKey, processingTimestamp, processingTimeMs,
    validEntriesCount, invalidEntriesCount, totalEntries,
    bulkRiskScore,        <- actimizeAnalyticsScore del UDT (máximo de entries)
    isAlertGenerated
  }
  bulkActions: [ { name, value, originalValue?, triggeredRules[] } ]
  bulkTriggeredRules: [ { ruleName, score, description? } ]
  entries: [
    {
      transactionKey, transactionId,
      riskLevelCode,   <- 1-6
      riskLevelLabel,  <- texto legible
      riskScore,
      decision,        <- BLOCK / REVIEW / APPROVE
      entryActions[],
      entryTriggeredRules[]
    }
  ]
}
```

### 1.2 Tabla de decisión riskLevel → decisión

| riskLevelCode | riskLevelLabel | riesgo relativo | decision IFM | Acción recomendada Core Banking |
|:---:|---|---|:---:|---|
| 1 | Very High | Muy alto | **BLOCK** | Rechazar la remesa, generar incidencia urgente |
| 2 | High | Alto | **BLOCK** | Rechazar la remesa, notificar al equipo AML |
| 3 | Medium High | Medio-alto | **REVIEW** | Poner en cola de revisión manual |
| 4 | Medium Low | Medio-bajo | **APPROVE** | Aprobar con registro en log de auditoría |
| 5 | Low | Bajo | **APPROVE** | Aprobar normalmente |
| 6 | Very Low | Muy bajo | **APPROVE** | Aprobar normalmente |

La decisión a nivel **BulkPayment** se deriva del `header.bulkRiskScore` (score máximo de todas las entries). El Core Banking puede complementar esta lógica con las decisiones individuales de cada entry si necesita granularidad por transacción.

### 1.3 Ejemplo A — Remesa con riskLevel=2 (High) → BLOCK

Escenario: batch con 3 remesas, una de ellas detectada como alto riesgo. El Policy Manager dispara la regla `COUNTER_PARTY_BLACKLIST` y establece acción `FREEZE_TRANSFER=YES`.

```json
{
  "schemaVersion": "1.0",
  "header": {
    "batchId": "BATCH-20260731-00042",
    "bulkTransactionKey": "BPK-9918273645",
    "processingTimestamp": "2026-07-31T10:23:45.312+02:00",
    "processingTimeMs": 1847,
    "validEntriesCount": 3,
    "invalidEntriesCount": 0,
    "totalEntries": 3,
    "bulkRiskScore": 87.5,
    "isAlertGenerated": true
  },
  "bulkActions": [
    {
      "name": "FREEZE_TRANSFER",
      "value": "YES",
      "originalValue": "NO",
      "triggeredRules": ["COUNTER_PARTY_BLACKLIST"]
    },
    {
      "name": "GENERATE_SAR",
      "value": "PENDING",
      "triggeredRules": ["HIGH_RISK_COUNTRY_DESTINATION"]
    }
  ],
  "bulkTriggeredRules": [
    {
      "ruleName": "COUNTER_PARTY_BLACKLIST",
      "score": 87.5,
      "description": "Beneficiario encontrado en lista OFAC SDN"
    },
    {
      "ruleName": "HIGH_RISK_COUNTRY_DESTINATION",
      "score": 65.0,
      "description": "Pais destino clasificado como alto riesgo FATF"
    }
  ],
  "entries": [
    {
      "transactionKey": "TXK-11001",
      "transactionId": "E2E-REMS-2026-001",
      "riskLevelCode": 2,
      "riskLevelLabel": "High",
      "riskScore": 87.5,
      "decision": "BLOCK",
      "entryActions": [
        {
          "name": "FREEZE_TRANSFER",
          "value": "YES",
          "originalValue": "NO",
          "triggeredRules": ["COUNTER_PARTY_BLACKLIST"]
        }
      ],
      "entryTriggeredRules": [
        {
          "ruleName": "COUNTER_PARTY_BLACKLIST",
          "score": 87.5,
          "description": "Beneficiario GB29NWBK60161331926819 en lista OFAC SDN"
        }
      ]
    },
    {
      "transactionKey": "TXK-11002",
      "transactionId": "E2E-REMS-2026-002",
      "riskLevelCode": 5,
      "riskLevelLabel": "Low",
      "riskScore": 12.3,
      "decision": "APPROVE",
      "entryActions": [],
      "entryTriggeredRules": []
    },
    {
      "transactionKey": "TXK-11003",
      "transactionId": "E2E-REMS-2026-003",
      "riskLevelCode": 5,
      "riskLevelLabel": "Low",
      "riskScore": 8.1,
      "decision": "APPROVE",
      "entryActions": [],
      "entryTriggeredRules": []
    }
  ]
}
```

### 1.4 Ejemplo B — Remesa con riskLevel=4 (Medium Low) → APPROVE

Escenario: batch con 2 remesas rutinarias sin señales de riesgo. Score máximo 23.7.

```json
{
  "schemaVersion": "1.0",
  "header": {
    "batchId": "BATCH-20260731-00043",
    "bulkTransactionKey": "BPK-9918273700",
    "processingTimestamp": "2026-07-31T10:31:02.089+02:00",
    "processingTimeMs": 312,
    "validEntriesCount": 2,
    "invalidEntriesCount": 0,
    "totalEntries": 2,
    "bulkRiskScore": 23.7,
    "isAlertGenerated": false
  },
  "bulkActions": [],
  "bulkTriggeredRules": [],
  "entries": [
    {
      "transactionKey": "TXK-11010",
      "transactionId": "E2E-REMS-2026-010",
      "riskLevelCode": 4,
      "riskLevelLabel": "Medium Low",
      "riskScore": 23.7,
      "decision": "APPROVE",
      "entryActions": [],
      "entryTriggeredRules": [
        {
          "ruleName": "AMOUNT_VELOCITY_CHECK",
          "score": 23.7,
          "description": "Importe ligeramente superior a la media del cliente"
        }
      ]
    },
    {
      "transactionKey": "TXK-11011",
      "transactionId": "E2E-REMS-2026-011",
      "riskLevelCode": 6,
      "riskLevelLabel": "Very Low",
      "riskScore": 3.2,
      "decision": "APPROVE",
      "entryActions": [],
      "entryTriggeredRules": []
    }
  ]
}
```

---

## 2. Qué implementar en Visual Modeler

IFM-X invoca dos exit points al finalizar el procesamiento de cada BulkPayment. Ambos deben implementarse como flows de Visual Modeler. A continuación se describe con detalle qué debe hacer cada flow.

### 2.1 Exit point ① — `FF_bulkPaymentBuildResponseMessageExitPoint`

**Propósito:** Construir el mensaje de respuesta JSON y guardarlo en `cs1` (y opcionalmente `cs2` para mensajes >4000 chars) para que IFM lo persista en BD.

**UDT de entrada disponible:**

| Campo UDT | Tipo | Descripción |
|---|---|---|
| `validEntriesCount` | Integer | Entries procesadas OK |
| `invalidEntriesCount` | Integer | Entries rechazadas |
| `totalNumberOfBulkPaymentEntries` | Integer | Total entries recibidas |
| `actimizeAnalyticsScore` | Decimal | Score máximo de todas las entries |
| `isAlertGenerated` | Boolean | Si se generó alerta |
| `actionRulesResults` | Set | FinalActions a nivel bulk (Name, Value, OriginalValue, TriggeredRules) |
| `scoringRulesResults` | Set | Reglas de scoring a nivel bulk |
| `Entries` | Set | Una fila por cada entry válida (ver subcampos abajo) |
| `Entries.bulkPaymentEntryFeed` | Structure | Datos originales de la entry (transactionId, etc.) |
| `Entries.entryResults.actimizeTransactionRiskScore` | Decimal | Score de la entry |
| `Entries.entryResults.riskLevel` | Integer | Nivel de riesgo 1-6 |
| `Entries.entryResults.actionRulesResults` | Set | FinalActions de la entry |
| `Entries.entryResults.scoringRulesResults` | Set | Reglas de scoring de la entry |

**Pseudocódigo del flow:**

```
FLOW: BuildBulkResponseMessage

-- 1. Obtener metadatos del BulkPayment desde contexto IFM
SET batchId        = GetContextValue("BatchId")
SET bpKey          = GetContextValue("BulkTransactionKey")
SET startTime      = GetContextValue("ProcessingStartTime")
SET now            = GetCurrentTimestamp()
SET processingMs   = TimeDiff(startTime, now, MILLISECONDS)

-- 2. Construir cabecera JSON
SET headerJson = BuildJsonObject(
    "batchId",             batchId,
    "bulkTransactionKey",  bpKey,
    "processingTimestamp", FormatISO8601(now),
    "processingTimeMs",    processingMs,
    "validEntriesCount",   UDT.validEntriesCount,
    "invalidEntriesCount", UDT.invalidEntriesCount,
    "totalEntries",        UDT.totalNumberOfBulkPaymentEntries,
    "bulkRiskScore",       UDT.actimizeAnalyticsScore,
    "isAlertGenerated",    UDT.isAlertGenerated
)

-- 3. Iterar actionRulesResults a nivel bulk
SET bulkActionsJson = "[]"
FOR EACH action IN UDT.actionRulesResults:
    SET actionObj = BuildJsonObject(
        "name",          action.Name,
        "value",         action.Value,
        "originalValue", action.OriginalValue,
        "triggeredRules", action.TriggeredRules  -- array de strings
    )
    SET bulkActionsJson = AppendToJsonArray(bulkActionsJson, actionObj)
END FOR

-- 4. Iterar scoringRulesResults a nivel bulk
SET bulkRulesJson = "[]"
FOR EACH rule IN UDT.scoringRulesResults:
    SET ruleObj = BuildJsonObject(
        "ruleName",    rule.RuleName,
        "score",       rule.Score,
        "description", rule.Description
    )
    SET bulkRulesJson = AppendToJsonArray(bulkRulesJson, ruleObj)
END FOR

-- 5. Iterar entries
SET entriesJson = "[]"
FOR EACH entry IN UDT.Entries:
    SET rl   = entry.entryResults.riskLevel
    SET decision = CASE rl
                     WHEN 1 THEN "BLOCK"
                     WHEN 2 THEN "BLOCK"
                     WHEN 3 THEN "REVIEW"
                     ELSE        "APPROVE"
                   END
    SET rlLabel = CASE rl
                    WHEN 1 THEN "Very High"
                    WHEN 2 THEN "High"
                    WHEN 3 THEN "Medium High"
                    WHEN 4 THEN "Medium Low"
                    WHEN 5 THEN "Low"
                    WHEN 6 THEN "Very Low"
                  END

    -- Construir entryActions
    SET entryActionsJson = "[]"
    FOR EACH ea IN entry.entryResults.actionRulesResults:
        SET entryActionsJson = AppendToJsonArray(entryActionsJson,
            BuildJsonObject("name", ea.Name, "value", ea.Value,
                            "originalValue", ea.OriginalValue,
                            "triggeredRules", ea.TriggeredRules))
    END FOR

    -- Construir entryTriggeredRules
    SET entryRulesJson = "[]"
    FOR EACH er IN entry.entryResults.scoringRulesResults:
        SET entryRulesJson = AppendToJsonArray(entryRulesJson,
            BuildJsonObject("ruleName", er.RuleName,
                            "score", er.Score,
                            "description", er.Description))
    END FOR

    SET entryObj = BuildJsonObject(
        "transactionKey",     entry.bulkPaymentEntryFeed.TransactionKey,
        "transactionId",      entry.bulkPaymentEntryFeed.EndToEndId,
        "riskLevelCode",      rl,
        "riskLevelLabel",     rlLabel,
        "riskScore",          entry.entryResults.actimizeTransactionRiskScore,
        "decision",           decision,
        "entryActions",       entryActionsJson,
        "entryTriggeredRules", entryRulesJson
    )
    SET entriesJson = AppendToJsonArray(entriesJson, entryObj)
END FOR

-- 6. Ensamblar mensaje final
SET responseMessage = BuildJsonObject(
    "schemaVersion",      "1.0",
    "header",             headerJson,
    "bulkActions",        bulkActionsJson,
    "bulkTriggeredRules", bulkRulesJson,
    "entries",            entriesJson
)

-- 7. Guardar en cs1 (IFM lo persiste en BD automáticamente)
-- Si el mensaje supera 4000 chars, partir en cs1 + cs2
IF Length(responseMessage) <= 4000:
    SET OutputUDT.cs1 = responseMessage
ELSE:
    SET OutputUDT.cs1 = SubString(responseMessage, 1, 4000)
    SET OutputUDT.cs2 = SubString(responseMessage, 4001, Length(responseMessage))
END IF

SET OutputUDT.responseMessage = responseMessage
```

> **Nota importante:** Las funciones `BuildJsonObject`, `AppendToJsonArray`, etc., son representaciones conceptuales. En Visual Modeler se implementan mediante llamadas a Java Actions o string concatenation activities disponibles en el toolbox de IFM-X. Consultar con el equipo de NICE Actimize la action library disponible en la versión instalada.

### 2.2 Exit point ② — `FF_bulkPaymentNotifyResponseMessageExitPoint`

**Propósito:** Tomar el mensaje construido en el exit point ① (disponible en `InputUDT.BulkPaymentResponseMessage.cs1`) y entregarlo al Core Banking por el canal configurado.

**UDT de entrada disponible:**

| Campo UDT | Tipo | Descripción |
|---|---|---|
| `isResend` | Boolean | `true` si es un reenvío manual, `false` en procesamiento normal |
| `BulkPaymentResponseMessage.cs1` | String | Mensaje JSON serializado (primeros 4000 chars) |
| `BulkPaymentResponseMessage.cs2` | String | Continuación del mensaje si superó 4000 chars |
| `BulkPaymentResponseMessage.responseMessage` | String | Mensaje completo si no se partió |

**Pseudocódigo del flow (lógica de routing):**

```
FLOW: NotifyBulkResponse

SET responseJson = Coalesce(
    InputUDT.BulkPaymentResponseMessage.responseMessage,
    Concat(InputUDT.BulkPaymentResponseMessage.cs1,
           InputUDT.BulkPaymentResponseMessage.cs2)
)

SET mode = GetConfigValue("FF_batchBulkPaymentResponseMessageMode")

SWITCH mode:
  CASE "MQ":
    CALL SubFlow_SendToMQ(responseJson)

  CASE "REST":
    CALL SubFlow_SendToREST(responseJson)

  CASE "FILE":
    CALL SubFlow_WriteToFile(responseJson)

  DEFAULT:
    LogWarning("FF_batchBulkPaymentResponseMessageMode no reconocido: " + mode)
END SWITCH

-- El isResend se puede usar para añadir un header/campo adicional
-- al mensaje o para cambiar la cola/endpoint de destino si el Core
-- Banking necesita distinguir reenvíos de procesamiento original.
IF InputUDT.isResend = true:
    LogInfo("Reenvio detectado para batch: " + ExtractBatchId(responseJson))
END IF
```

---

## 3. Opción A — IBM MQ

### 3.1 Descripción

IFM-X coloca el mensaje de respuesta JSON en una cola IBM MQ. El Core Banking tiene un consumer MQ (listener/JMS/MQ API) que lee los mensajes y los procesa de forma asíncrona. Esta arquitectura desacopla completamente IFM del Core Banking: si el CB está momentáneamente saturado, los mensajes se acumulan en la cola sin afectar al throughput de IFM.

```
IFM-X                    IBM MQ                  Core Banking
  │                        │                          │
  │── PUT(responseJSON) ──>│ IFM.REMITTANCES.RESPONSE │
  │                        │<── GET(responseJSON) ────│
  │                        │                          │── Procesar respuesta
```

### 3.2 Configuración requerida

**`FF_applicationConfig.ini`** (instancia `Actimize_IFM_RT1`):

```ini
[BulkPayment]
; OBLIGATORIO para MQ: el exit point de notificación debe ser async
; para que IFM no espere confirmación del delivery antes de continuar
FF_batchBulkPaymentResponseMessageMode=async

; Cola MQ donde IFM depositará las respuestas
FF_bulkPaymentMQResponseQueue=IFM.REMITTANCES.RESPONSE

; Queue Manager MQ (configurar según entorno)
FF_bulkPaymentMQQueueManager=<MQ_QUEUE_MANAGER_NAME>
```

**`FF_environmentConfig.ini`** (específico de cada entorno):

```ini
[MQConnection]
FF_MQHost=<MQ_HOST>
FF_MQPort=<MQ_PORT>
FF_MQChannel=<MQ_CHANNEL>
; Ejemplo de valores reales (sustituir por los de cada entorno):
; FF_MQHost=mqserver.internal.banco.es
; FF_MQPort=1414
; FF_MQChannel=IFM.TO.CB.SVRCONN
```

### 3.3 Implementación en Visual Modeler — SubFlow_SendToMQ

```
SUBFLOW: SendToMQ
INPUT: responseJson (String)

-- 1. Obtener parámetros de conexión del config
SET queueManager = GetConfigValue("FF_bulkPaymentMQQueueManager")
SET host         = GetConfigValue("FF_MQHost")
SET port         = GetConfigValue("FF_MQPort")
SET channel      = GetConfigValue("FF_MQChannel")
SET queueName    = GetConfigValue("FF_bulkPaymentMQResponseQueue")

-- 2. Crear conexión MQ usando MQSeries Java API (disponible en classpath IFM)
SET mqEnv = CreateMQEnvironment(host, port, channel)
SET conn  = MQQueueManager.Connect(queueManager, mqEnv)
SET queue = conn.OpenQueue(queueName, MQOO_OUTPUT)

-- 3. Construir el MQMessage
SET msg = CreateMQMessage()
SET msg.format       = MQFMT_STRING
SET msg.characterSet = 1208              -- UTF-8
SET msg.writeString(responseJson)

-- 4. Opciones de PUT: persistente para garantizar no pérdida
SET pmo = CreateMQPutMessageOptions()
SET pmo.options = MQPMO_PERSISTENT

-- 5. PUT del mensaje
queue.Put(msg, pmo)
LogInfo("MQ PUT OK - Queue: " + queueName + " - Correlación: " + msg.messageId)

-- 6. Cierre ordenado de recursos
queue.Close()
conn.Disconnect()

ON ERROR:
    LogError("Error MQ PUT: " + ErrorMessage)
    -- Si MQ no está disponible, IFM registra el error en log
    -- El Core Banking puede solicitar reenvío vía isResend=true
    RAISE IFMDeliveryException(ErrorMessage)
```

### 3.4 Ventajas e inconvenientes

**Ventajas:**
- Fiabilidad garantizada: IBM MQ asegura entrega exactly-once con mensajes persistentes
- No bloquea IFM: el PUT es prácticamente instantáneo, IFM sigue procesando
- Estándar bancario: la mayoría de Core Bankings tienen consumer MQ
- Reintentos automáticos por parte de AMQ si la cola está temporalmente no disponible
- Dead Letter Queue automática si el CB no puede procesar el mensaje

**Inconvenientes:**
- El Core Banking necesita implementar y operar un consumer MQ
- Latencia eventual: el CB procesa cuando puede, no hay respuesta síncrona a IFM
- Requiere licencia y operación de IBM MQ en el entorno

### 3.5 Cuándo elegir esta opción

Elegir MQ cuando:
- El Core Banking ya dispone de infraestructura IBM MQ y consume otras colas
- Se requiere máxima fiabilidad en entorno de producción
- El volumen de remesas es alto y la latencia de entrega individual no es crítica
- El equipo de operaciones tiene experiencia con IBM MQ

### 3.6 Script de prueba

Ver `scripts/actimize/response/Test-MQResponse.ps1`. El script simula el consumer del Core Banking.

Ejemplo de ejecución:
```powershell
.\Test-MQResponse.ps1 `
    -QueueManager "QMGR_PRE" `
    -Channel "IFM.TO.CB.SVRCONN" `
    -Host "<MQ_HOST>" `
    -Port 1414 `
    -Queue "IFM.REMITTANCES.RESPONSE"
```

---

## 4. Opción B — REST

### 4.1 Descripción

IFM-X realiza un HTTP POST con el mensaje de respuesta JSON al endpoint del Core Banking. El CB expone una API REST que recibe la respuesta de IFM en tiempo cuasi-real.

```
IFM-X                                    Core Banking API
  │                                           │
  │── POST /api/ifm/bulk-response ───────────>│
  │   Body: { responseJSON }                  │── Persiste y procesa
  │<── 200 OK {"status":"received"} ──────────│
```

### 4.2 Configuración requerida

**`FF_applicationConfig.ini`**:

```ini
[BulkPayment]
; async: IFM hace el POST pero no espera respuesta del CB para continuar
; sync: IFM espera la respuesta HTTP antes de marcar el batch como completado
; Recomendado async para no penalizar el throughput de IFM
FF_batchBulkPaymentResponseMessageMode=async

; URL del endpoint receptor del Core Banking
FF_bulkPaymentRESTEndpoint=http://<CB_HOST>:<CB_PORT>/api/ifm/bulk-response

; Timeout HTTP en milisegundos (recomendado: 5000)
FF_bulkPaymentRESTTimeoutMs=5000

; Si el CB requiere autenticación, configurar API key o token
FF_bulkPaymentRESTAuthHeader=Authorization
FF_bulkPaymentRESTAuthValue=Bearer <CB_API_TOKEN>
```

**`FF_environmentConfig.ini`**:

```ini
[RESTConnection]
FF_CBRestHost=<CB_HOST>
FF_CBRestPort=<CB_PORT>
; Ejemplos:
; FF_CBRestHost=corebanking-api.interno.banco.es
; FF_CBRestPort=8443
```

### 4.3 Implementación en Visual Modeler — SubFlow_SendToREST

```
SUBFLOW: SendToREST
INPUT: responseJson (String)

-- 1. Obtener endpoint y credenciales del config
SET endpoint    = GetConfigValue("FF_bulkPaymentRESTEndpoint")
SET timeoutMs   = GetConfigValue("FF_bulkPaymentRESTTimeoutMs")
SET authHeader  = GetConfigValue("FF_bulkPaymentRESTAuthHeader")
SET authValue   = GetConfigValue("FF_bulkPaymentRESTAuthValue")

-- 2. Construir HttpRequest via Java Action (HttpClient disponible en IFM)
SET client = CreateHttpClient(timeoutMs)
SET request = CreateHttpPostRequest(endpoint)
SET request.AddHeader("Content-Type", "application/json; charset=UTF-8")
SET request.AddHeader("X-IFM-Source", "IFM-X-REMESAS")
IF authHeader != "":
    SET request.AddHeader(authHeader, authValue)
SET request.SetBody(responseJson)

-- 3. Ejecutar POST
SET response = client.Execute(request)
LogInfo("REST POST - Endpoint: " + endpoint +
        " - HTTP Status: " + response.StatusCode)

-- 4. Verificar respuesta
IF response.StatusCode >= 200 AND response.StatusCode < 300:
    LogInfo("Entrega REST OK")
ELSE:
    LogError("REST POST fallido. Status: " + response.StatusCode +
             " Body: " + response.Body)
    RAISE IFMDeliveryException("HTTP " + response.StatusCode)
END IF

ON ERROR (timeout, connection refused):
    LogError("Error conexión REST: " + ErrorMessage)
    RAISE IFMDeliveryException(ErrorMessage)
```

### 4.4 Contrato del endpoint receptor

El Core Banking debe exponer:

```
POST /api/ifm/bulk-response
Content-Type: application/json
X-IFM-Source: IFM-X-REMESAS

Body: { <ifm-bulk-response-v1 JSON> }

Respuesta OK:
HTTP 200
{ "status": "received", "batchId": "<echo del batchId>" }

Respuesta error (para que IFM lo registre):
HTTP 4xx/5xx
{ "error": "<descripcion>" }
```

### 4.5 Ventajas e inconvenientes

**Ventajas:**
- Universalmente soportado: cualquier plataforma puede exponer un endpoint HTTP
- Debugging sencillo: se puede probar con `curl` o Postman sin herramientas especiales
- Sin infraestructura adicional si el CB ya tiene API REST
- Respuesta inmediata: el CB puede devolver un 422 si detecta que el JSON es inválido

**Inconvenientes:**
- Si el CB está caído o lento, IFM puede acumular timeouts (mitigar con modo `async`)
- Sin reintentos automáticos nativos (habría que implementarlos en el flow de VM)
- El CB debe exponer un endpoint accesible desde la red de IFM (revisar firewall)

### 4.6 Cuándo elegir esta opción

Elegir REST cuando:
- El Core Banking ya tiene API REST y puede añadir un endpoint fácilmente
- La latencia de respuesta del CB es predecible y baja (<2s en condiciones normales)
- Se desea máximo control y visibilidad del delivery (logs HTTP en ambos extremos)
- Entorno PRE/UAT donde la simplicidad de debugging es prioritaria

### 4.7 Script de prueba

Ver `scripts/actimize/response/Start-RESTReceiver.ps1`. El script levanta un servidor HTTP local que simula el endpoint del Core Banking.

Ejemplo de ejecución en la máquina donde corre IFM (apuntar `FF_bulkPaymentRESTEndpoint` a localhost):
```powershell
.\Start-RESTReceiver.ps1 -Port 8080 -LogDir "C:\Actimize\IFM\test\rest-logs"
```

Para probar manualmente con curl:
```bash
curl -X POST http://localhost:8080/api/ifm/bulk-response \
     -H "Content-Type: application/json" \
     -d @ejemplo-respuesta.json
```

---

## 5. Opción C — Fichero

### 5.1 Descripción

IFM-X escribe un fichero JSON de respuesta en una carpeta compartida (UNC o local). El Core Banking tiene un proceso de polling que detecta ficheros nuevos, los lee y los procesa.

```
IFM-X                     Carpeta compartida         Core Banking
  │                              │                        │
  │── Escribe RESPONSE_*.json ──>│                        │
  │                              │<── Poll cada N seg ────│
  │                              │                        │── Lee y procesa
  │                              │                        │── Mueve a \processed\
```

### 5.2 Nomenclatura de ficheros

```
RESPONSE_{batchId}_{yyyyMMdd_HHmmss_fff}.json

Ejemplos:
  RESPONSE_BATCH-20260731-00042_20260731_102345_312.json
  RESPONSE_BATCH-20260731-00043_20260731_103102_089.json
```

La inclusión del timestamp en millisegundos garantiza unicidad incluso si el mismo batchId se reenvía múltiples veces.

### 5.3 Estructura de carpetas

```
C:\Actimize\IFM\responses\
├── (ficheros nuevos, pendientes de leer por el CB)
└── processed\
    └── (ficheros ya procesados, archivados por el CB o el watcher)
```

### 5.4 Configuración requerida

**`FF_applicationConfig.ini`**:

```ini
[BulkPayment]
FF_batchBulkPaymentResponseMessageMode=async

; Carpeta donde IFM escribe los ficheros de respuesta
; Puede ser ruta UNC para carpeta compartida con el CB
FF_bulkPaymentResponseFileOutputDir=C:\Actimize\IFM\responses\

; Encoding del fichero (recomendado UTF-8)
FF_bulkPaymentResponseFileEncoding=UTF-8
```

### 5.5 Implementación en Visual Modeler — SubFlow_WriteToFile

```
SUBFLOW: WriteToFile
INPUT: responseJson (String)

-- 1. Obtener carpeta de salida del config
SET outputDir = GetConfigValue("FF_bulkPaymentResponseFileOutputDir")
SET encoding  = GetConfigValue("FF_bulkPaymentResponseFileEncoding")

-- 2. Extraer batchId del JSON para el nombre del fichero
SET batchId   = JsonExtract(responseJson, "$.header.batchId")
SET timestamp = FormatTimestamp(Now(), "yyyyMMdd_HHmmss_fff")
SET fileName  = "RESPONSE_" + batchId + "_" + timestamp + ".json"
SET filePath  = outputDir + fileName

-- 3. Escribir fichero (operación atómica: escribir a .tmp, renombrar a .json)
-- El rename garantiza que el CB nunca lee un fichero a medias
SET tmpPath = filePath + ".tmp"
WriteFile(tmpPath, responseJson, encoding)
RenameFile(tmpPath, filePath)

LogInfo("Fichero respuesta escrito: " + filePath)

ON ERROR:
    LogError("Error escribiendo fichero respuesta: " + ErrorMessage +
             " Path: " + filePath)
    RAISE IFMDeliveryException(ErrorMessage)
```

> **Importante:** La escritura en dos pasos (`.tmp` → `.json`) es crítica. Si IFM escribe directamente el `.json`, el CB podría leer un fichero incompleto durante la escritura. El Core Banking (y el script de watcher) solo debe procesar ficheros con extensión `.json`, ignorando `.tmp`.

### 5.6 Ventajas e inconvenientes

**Ventajas:**
- Sin dependencias de red en el momento de entrega: IFM escribe localmente o en UNC
- Debugging inmediato: basta con abrir el fichero con un editor de texto
- Sin infraestructura adicional: solo hace falta una carpeta compartida
- Los ficheros sirven como audit trail natural

**Inconvenientes:**
- El CB debe implementar y operar un proceso de polling (FileSystemWatcher o scheduler)
- Requiere carpeta compartida UNC accesible desde ambos sistemas (considerar permisos, antivirus)
- Latencia: el CB procesa cuando ejecuta el poll, no inmediatamente
- Acumulación de ficheros si el CB falla: necesita gestión de carpeta procesada

### 5.7 Cuándo elegir esta opción

Elegir fichero cuando:
- Entorno DEV o PRE donde la simplicidad de debugging prima sobre la sofisticación
- No hay MQ ni API REST disponibles
- El volumen de remesas es bajo y la latencia de respuesta no es crítica
- El equipo quiere la opción más sencilla para una primera validación del flujo

### 5.8 Script de prueba (watcher)

Ver `scripts/actimize/response/Watch-FileResponse.ps1`. El script simula el consumer del Core Banking basado en FileSystemWatcher.

Ejemplo de ejecución:
```powershell
.\Watch-FileResponse.ps1 `
    -WatchDir "C:\Actimize\IFM\responses" `
    -ArchiveDir "C:\Actimize\IFM\responses\processed"
```

---

## 6. Comparativa y recomendación

### 6.1 Tabla comparativa

| Criterio | A — IBM MQ | B — REST | C — Fichero |
|---|:---:|:---:|:---:|
| **Fiabilidad de entrega** | ★★★★★ | ★★★★☆ | ★★★☆☆ |
| **Latencia de respuesta** | Eventual (segundos) | Cuasi-real (<1s) | Eventual (poll interval) |
| **Complejidad de implementación IFM** | Media | Baja | Muy baja |
| **Complejidad de implementación CB** | Alta (consumer MQ) | Baja (endpoint REST) | Media (polling + archivado) |
| **Debugging en producción** | Medio (herramientas MQ) | Alto (curl/Postman/logs HTTP) | Muy alto (abrir fichero) |
| **Dependencias de infraestructura** | IBM MQ instalado y operativo | Red entre IFM y CB, firewall abierto | Carpeta compartida UNC |
| **Modo recomendado (sync/async)** | async (obligatorio) | async (recomendado) | async |
| **Adecuado para PRO** | ✅ Sí | ✅ Sí (con HA) | ⚠️ Solo si no hay alternativa |
| **Adecuado para PRE** | ✅ Sí | ✅ Sí (recomendado) | ✅ Sí |
| **Adecuado para DEV** | ⚠️ Solo si hay MQ local | ✅ Sí | ✅ Sí (recomendado) |
| **Reintentos automáticos** | Sí (AMQ DLQ) | No (implementar en VM) | No (manual/script) |
| **Audit trail** | MQ logs | Logs HTTP CB y IFM | Ficheros en `\processed\` |

### 6.2 Recomendación por entorno

| Entorno | Opción recomendada | Justificación |
|---|---|---|
| **PRODUCCIÓN** | **A — IBM MQ** | Máxima fiabilidad, sin pérdida de mensajes, desacoplamiento total, estándar bancario para integración entre sistemas críticos |
| **PRE-PRODUCCIÓN / UAT** | **B — REST** | Debugging ágil con herramientas estándar, fácil de configurar, permite validar el contrato JSON del endpoint que irá a PRO |
| **DESARROLLO / LOCAL** | **C — Fichero** | Cero dependencias externas, los ficheros JSON son legibles inmediatamente, ideal para iterar rápido sobre el formato del mensaje |

> **Nota de migración:** Si se empieza con Fichero en DEV y REST en PRE, la transición a MQ en PRO solo requiere cambiar `FF_batchBulkPaymentResponseMessageMode` y el subflow de entrega en el exit point ②. El formato del mensaje JSON es idéntico en las tres opciones.

---

## 7. Plan de pruebas para cada opción

### 7.1 Casos de prueba

#### TC-01: Batch con todas las entries CLEAR (riskLevel 4-6)

**Objetivo:** Verificar que IFM genera un mensaje de respuesta correcto cuando no hay riesgo.  
**Setup:** Preparar XML de entrada con 3 entries con importes y beneficiarios habituales, ninguno en listas.  
**Resultado esperado:**
- `header.bulkRiskScore` < 30
- `header.isAlertGenerated` = false
- `bulkActions` = []
- Todas las entries con `decision` = "APPROVE"

**Cómo verificar:**
```
# En ff_bulk_access.log buscar:
grep "BATCH-TC01" C:\Actimize\ais_server\Instances\Actimize_IFM_RT1\Logs\ff_bulk_access.log

# En AIS process log buscar completado sin errores:
grep "BulkPayment.*TC01.*Completed" C:\Actimize\ais_server\Instances\Actimize_IFM_RT1\Logs\ais_process.log
```

#### TC-02: Batch con una entry HIGH risk (riskLevel 2)

**Objetivo:** Verificar que el Policy Manager dispara acciones y la decisión es BLOCK.  
**Setup:** Incluir una entry cuyo beneficiario esté en la lista de prueba configurada en IFM, o con un patrón de importe que dispare la regla de alto riesgo.  
**Resultado esperado:**
- `header.bulkRiskScore` >= 70
- `header.isAlertGenerated` = true
- Al menos un action `FREEZE_TRANSFER=YES` (o el equivalente configurado)
- La entry problemática con `riskLevelCode` = 1 o 2 y `decision` = "BLOCK"
- Las demás entries sin acciones

**Cómo verificar (opción MQ):**
```powershell
.\Test-MQResponse.ps1 -QueueManager "QMGR_DEV" -Channel "SVRCONN" `
    -Host "<MQ_HOST>" -Port 1414 -Queue "IFM.REMITTANCES.RESPONSE"
# Esperar el mensaje y verificar en consola que imprime "BLOCK" para la entry problemática
```

**Cómo verificar (opción REST):**
```powershell
# En una ventana: levantar el receiver
.\Start-RESTReceiver.ps1 -Port 8080
# En otra ventana: configurar IFM para apuntar a localhost:8080 y enviar el batch
# El receiver imprimirá el JSON recibido; verificar los campos decision
```

**Cómo verificar (opción Fichero):**
```powershell
.\Watch-FileResponse.ps1 -WatchDir "C:\Actimize\IFM\responses"
# Al llegar el batch, el watcher imprime el resumen con la entry HIGH resaltada
```

#### TC-03: Batch con entries inválidas

**Objetivo:** Verificar que las entries inválidas se cuentan correctamente y no aparecen en el array `entries`.  
**Setup:** XML con 5 entries, 2 de ellas con campos obligatorios faltantes o IBAN malformado.  
**Resultado esperado:**
- `header.validEntriesCount` = 3
- `header.invalidEntriesCount` = 2
- `header.totalEntries` = 5
- `entries` array con exactamente 3 elementos

#### TC-04: Reenvío manual (isResend=true)

**Objetivo:** Verificar que el flow distingue un reenvío y que el mensaje llega sin duplicados problemáticos.  
**Setup:** Procesar un batch que entregó OK. Luego solicitar reenvío manual desde la consola IFM.  
**Resultado esperado:**
- El log de IFM registra "Reenvio detectado para batch: <batchId>"
- El mensaje llega al CB/cola/fichero con el mismo contenido que el original
- El CB debe tener lógica de idempotencia (misma `bulkTransactionKey` ya procesada)

#### TC-05: Fallo del canal de entrega

**Objetivo:** Verificar el comportamiento de IFM cuando el canal de entrega falla.  
**Setup (MQ):** Parar el servidor MQ antes de procesar el batch.  
**Setup (REST):** Parar el receiver antes de procesar el batch.  
**Setup (Fichero):** Quitar permisos de escritura sobre la carpeta de salida.  
**Resultado esperado:**
- IFM registra el error en `ais_process.log` con nivel ERROR
- El batch queda en estado de error en la consola IFM (no en "Completed")
- No se pierde el mensaje: está en `responseMessage` en BD

### 7.2 Verificación en logs de IFM

| Qué buscar | Fichero de log | Patron de búsqueda |
|---|---|---|
| Inicio procesamiento del batch | `ff_bulk_access.log` | `BulkPayment.*<batchId>.*Started` |
| Fin procesamiento del batch | `ff_bulk_access.log` | `BulkPayment.*<batchId>.*Completed` |
| Score calculado | `ff_bulk_access.log` | `actimizeAnalyticsScore.*<batchId>` |
| Error en exit point | `ais_process.log` | `ERROR.*<batchId>` |
| Exit point ① ejecutado | `ais_process.log` | `BuildResponseMessage.*<batchId>` |
| Exit point ② ejecutado | `ais_process.log` | `NotifyResponseMessage.*<batchId>` |
| Error de entrega MQ | `ais_process.log` | `MQ PUT.*ERROR` |
| Error de entrega REST | `ais_process.log` | `REST POST.*HTTP [45]` |
| Error de escritura fichero | `ais_process.log` | `WriteFile.*ERROR` |

**Ruta de logs:**
```
C:\Actimize\ais_server\Instances\Actimize_IFM_RT1\Logs\
```

### 7.3 Checklist de validación end-to-end

Antes de pasar a producción, verificar que:

- [ ] El schema del mensaje generado por IFM valida contra `schemas/remesas/ifm-bulk-response-v1.json`
- [ ] Los campos `riskLevelCode`, `riskLevelLabel` y `decision` son consistentes entre sí
- [ ] El `header.bulkRiskScore` es igual al máximo de `entries[*].riskScore`
- [ ] `header.validEntriesCount` == `entries.length`
- [ ] Las entries con `riskLevelCode` 1-2 tienen `decision` = "BLOCK"
- [ ] Las entries con `riskLevelCode` = 3 tienen `decision` = "REVIEW"
- [ ] Las entries con `riskLevelCode` 4-6 tienen `decision` = "APPROVE"
- [ ] El reenvío (isResend=true) genera el mismo mensaje que el original
- [ ] En caso de fallo del canal de entrega, el error queda registrado en log y el mensaje está en BD
- [ ] El CB tiene lógica de idempotencia ante `bulkTransactionKey` duplicadas
