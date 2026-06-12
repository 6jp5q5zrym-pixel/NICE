# Arquitectura de Integración: Remesas → NICE Actimize

## 1. Productos Actimize Relevantes para Remesas

| Producto | Sigla | Función | Aplicación en Remesas |
|----------|-------|---------|----------------------|
| **Suspicious Activity Monitoring** | SAM | Detección de actividad sospechosa mediante reglas y modelos ML | Detección de structuring, funnel accounts, actividad inusual |
| **Watchlist Filtering** | WLF | Screening en tiempo real contra listas de sanciones | OFAC, EU Consolidated List, ONU, PEP lists |
| **Customer Due Diligence** | CDD | Gestión del ciclo de vida KYC del cliente | Perfil de riesgo remesas, enhanced due diligence |
| **ActOne** | ActOne | Gestión de casos y workflow de investigación | Gestión de alertas AML generadas por SAM/WLF |
| **IFM-x** | IFM | Detección de fraude en pagos | Fraude en transferencias online / APP fraud |

---

## 2. Arquitectura de Alto Nivel

```
┌─────────────────────────────────────────────────────────────────────┐
│                         SISTEMAS FUENTE                              │
│  Core Bancario   │  SWIFT Alliance  │  Canal Digital  │  MTO APIs   │
│  (Transacciones) │  (MT103/pacs008) │  (Banca Online) │  (WU/MG)   │
└────────┬─────────┴────────┬─────────┴────────┬────────┴──────┬──────┘
         │                  │                   │               │
         └──────────────────┴───────────────────┴───────────────┘
                                    │
                          ┌─────────▼──────────┐
                          │   CAPA DE INGESTIÓN │
                          │  (ETL / Streaming)  │
                          │  - Kafka / MQ       │
                          │  - Batch FTP/SFTP   │
                          │  - REST API         │
                          └─────────┬──────────┘
                                    │
                 ┌──────────────────┼──────────────────┐
                 │                  │                   │
        ┌────────▼───────┐ ┌────────▼───────┐ ┌────────▼───────┐
        │   ACTIMIZE WLF │ │  ACTIMIZE SAM  │ │  ACTIMIZE CDD  │
        │  Screening RT  │ │  Monitorización│ │  Perfil Riesgo │
        │  Sanciones/PEP │ │  Comportamtal  │ │  KYC/EDD       │
        └────────┬───────┘ └────────┬───────┘ └────────┬───────┘
                 │                  │                   │
                 └──────────────────┼───────────────────┘
                                    │
                          ┌─────────▼──────────┐
                          │    ACTONE (Cases)   │
                          │  Gestión de Alertas │
                          │  Workflow Analista  │
                          │  SAR / Reporting    │
                          └────────────────────┘
```

---

## 3. Modelo de Datos para Remesas en Actimize

### 3.1 Tabla de Transacciones (TRANSACTION)

```sql
-- Esquema canónico para ingestión de remesas en Actimize SAM
CREATE TABLE ACT_REMESAS_TRANSACTION (
    -- Identificadores
    TRN_ID              VARCHAR(50)     NOT NULL,   -- Referencia única :20: MT103
    UETR                VARCHAR(36),                -- UUID gpi (pacs.008)
    BATCH_ID            VARCHAR(50),                -- ID batch de carga
    
    -- Fechas
    TXN_DATE            DATE            NOT NULL,   -- Fecha de la transacción
    VALUE_DATE          DATE,                       -- Fecha valor :32A:
    LOAD_TIMESTAMP      TIMESTAMP,                  -- Timestamp carga en Actimize
    
    -- Importes
    AMOUNT_ORIG         DECIMAL(18,2)   NOT NULL,   -- Importe en divisa origen
    CURRENCY_ORIG       CHAR(3)         NOT NULL,   -- ISO 4217 (EUR, USD...)
    AMOUNT_EUR          DECIMAL(18,2),              -- Importe equivalente EUR
    FX_RATE             DECIMAL(12,6),              -- Tipo de cambio aplicado
    
    -- Ordenante (Sender)
    SENDER_ACCOUNT      VARCHAR(34),                -- IBAN / BBAN ordenante
    SENDER_NAME         VARCHAR(140),               -- Nombre ordenante :50K:
    SENDER_ADDRESS      VARCHAR(255),               -- Dirección ordenante
    SENDER_COUNTRY      CHAR(2),                    -- ISO 3166-1 alpha-2
    SENDER_CUSTOMER_ID  VARCHAR(50),                -- ID interno cliente
    SENDER_BIC          CHAR(11),                   -- BIC banco ordenante :52A:
    
    -- Beneficiario (Receiver)  
    RECEIVER_ACCOUNT    VARCHAR(34),                -- IBAN / cuenta beneficiario
    RECEIVER_NAME       VARCHAR(140),               -- Nombre beneficiario :59:
    RECEIVER_ADDRESS    VARCHAR(255),               -- Dirección beneficiario
    RECEIVER_COUNTRY    CHAR(2),                    -- País beneficiario
    RECEIVER_BIC        CHAR(11),                   -- BIC banco beneficiario :57A:
    
    -- Intermediarios
    INTERMEDIARY_BIC    VARCHAR(11),                -- Banco corresponsal :56A:
    
    -- Clasificación
    TXN_TYPE            VARCHAR(20),                -- REMESA / WIRE / SEPA_CT
    PURPOSE_CODE        CHAR(4),                    -- ISO 20022: FAMI, SALA, TRAD...
    PAYMENT_METHOD      VARCHAR(20),                -- SWIFT / SEPA / MTO / CASH
    CHANNEL             VARCHAR(20),                -- ONLINE / BRANCH / API / BATCH
    
    -- Información regulatoria
    REGULATORY_INFO     VARCHAR(500),               -- Campo :77B: MT103
    ORDERING_INSTITUTION VARCHAR(140),
    
    -- Metadatos Actimize
    ACT_ENTITY_ID       VARCHAR(50),                -- Entidad Actimize vinculada
    ACT_ALERT_FLAG      CHAR(1) DEFAULT 'N',        -- Flag alerta generada
    ACT_LOAD_STATUS     VARCHAR(20) DEFAULT 'PENDING',
    
    CONSTRAINT PK_REMESAS_TXN PRIMARY KEY (TRN_ID)
);

-- Índices para rendimiento en consultas SAM
CREATE INDEX IDX_SENDER_CUST   ON ACT_REMESAS_TRANSACTION (SENDER_CUSTOMER_ID, TXN_DATE);
CREATE INDEX IDX_RECEIVER_ACC  ON ACT_REMESAS_TRANSACTION (RECEIVER_ACCOUNT, TXN_DATE);
CREATE INDEX IDX_RECEIVER_CTRY ON ACT_REMESAS_TRANSACTION (RECEIVER_COUNTRY, TXN_DATE);
CREATE INDEX IDX_VALUE_DATE    ON ACT_REMESAS_TRANSACTION (VALUE_DATE);
CREATE INDEX IDX_AMOUNT_EUR    ON ACT_REMESAS_TRANSACTION (AMOUNT_EUR);
```

### 3.2 Tabla de Entidades / Clientes (ENTITY)

```sql
CREATE TABLE ACT_REMESAS_ENTITY (
    ENTITY_ID           VARCHAR(50)     NOT NULL,   -- ID interno cliente
    ENTITY_TYPE         VARCHAR(20),                -- INDIVIDUAL / CORPORATE
    
    -- Datos personales
    FULL_NAME           VARCHAR(200)    NOT NULL,
    DOC_TYPE            VARCHAR(10),                -- DNI / NIE / PASAPORTE
    DOC_NUMBER          VARCHAR(30),
    NATIONALITY         CHAR(2),                    -- ISO 3166-1
    RESIDENCE_COUNTRY   CHAR(2),
    DATE_OF_BIRTH       DATE,
    
    -- Perfil de riesgo
    RISK_RATING         VARCHAR(10),                -- LOW / MEDIUM / HIGH / VH
    PEP_FLAG            CHAR(1) DEFAULT 'N',        -- Persona Políticamente Expuesta
    SANCTIONS_FLAG      CHAR(1) DEFAULT 'N',
    ADVERSE_MEDIA_FLAG  CHAR(1) DEFAULT 'N',
    
    -- Perfil de remesas (actualizado periódicamente)
    REMIT_AVG_MONTHLY_AMT   DECIMAL(18,2),          -- Importe medio mensual
    REMIT_AVG_FREQ_MONTHLY  INTEGER,                -- Frecuencia media mensual
    REMIT_USUAL_CORRIDORS   VARCHAR(500),           -- JSON: países habituales
    REMIT_FIRST_DATE        DATE,
    REMIT_LAST_DATE         DATE,
    
    -- Segmentación
    OCCUPATION_CODE     VARCHAR(10),                -- Código CNAE / ocupación
    DECLARED_INCOME_EUR DECIMAL(18,2),              -- Ingresos declarados anuales
    
    -- Metadatos
    ONBOARDING_DATE     DATE,
    LAST_REVIEW_DATE    DATE,
    NEXT_REVIEW_DATE    DATE,
    
    CONSTRAINT PK_REMESAS_ENTITY PRIMARY KEY (ENTITY_ID)
);
```

---

## 4. Patrones de Integración

### 4.1 Batch (Fichero Plano) — Patrón Más Común

```
Core Bancario → [Extracción noche T] → [SFTP Seguro] → [Actimize Input Folder] → [SAM Batch Job]
```

**Especificaciones del fichero:**
- Formato: CSV delimitado por `|` o Fixed-Width
- Codificación: UTF-8
- Nomenclatura: `REMESAS_YYYYMMDD_HHMM_NNN.dat`
- Cifrado: PGP con clave pública Actimize
- Compresión: gzip (.gz)
- Envío: SFTP a `/actimize/input/remesas/`
- Horario: Carga nocturna a las 02:00 (D-1)

**Formato cabecera del fichero:**
```
HDR|REMESAS|20240612|020000|000001|1234|BANCO_EJEMPLO
TRN|...|...|...
TRN|...|...|...
TRL|000001|1234|1234567.89
```

### 4.2 Streaming en Tiempo Real (Kafka)

Para remesas con requisito de screening en tiempo real (SCT Inst, WLF):

```
MT103 recibido → Parser SWIFT → Kafka Topic: remesas.inbound → Actimize WLF Consumer
                                                              → Actimize SAM RT Consumer
```

**Topic Kafka:** `banco.actimize.remesas.realtime`  
**Formato mensaje:** JSON (ver schema en `/schemas/remesas/remesa-event-v1.json`)  
**Latencia objetivo WLF:** < 500ms desde recepción MT103  
**Latencia objetivo SAM RT:** < 5 segundos

### 4.3 API REST (Actimize ReST Interface)

Para integraciones puntuales o consultas ad-hoc:

```bash
POST /actimize/api/v2/transactions
Authorization: Bearer <JWT_TOKEN>
Content-Type: application/json

{
  "transactionId": "TRN20240612001",
  "transactionDate": "2024-06-12",
  "amount": 850.00,
  "currency": "EUR",
  "sender": { ... },
  "receiver": { ... },
  "transactionType": "REMESA"
}
```

---

## 5. Reglas AML en Actimize SAM para Remesas

### 5.1 Reglas Basadas en Umbrales

| ID Regla | Nombre | Lógica | Umbral | Puntuación |
|----------|--------|--------|--------|------------|
| REM-001 | Structuring Diario | Suma de remesas en D < umbral declaración | > 9.000 € / día | 75 |
| REM-002 | Structuring Semanal | Suma de remesas en 7D | > 25.000 € / 7 días | 70 |
| REM-003 | Importe Único Elevado | Remesa individual | > 5.000 € | 60 |
| REM-004 | País FATF Lista Gris | Destino en lista gris FATF | Cualquier importe | 65 |
| REM-005 | País Sanciones | Destino en país sancionado | Cualquier importe | 95 |

### 5.2 Reglas de Comportamiento (Behavioral)

| ID Regla | Nombre | Lógica |
|----------|--------|--------|
| REM-010 | Incremento Volumen Anómalo | Volumen mensual > 300% de media histórica |
| REM-011 | Nuevo Corredor Geográfico | Primer envío a país no habitual en últimos 12M |
| REM-012 | Múltiples Beneficiarios | > 5 beneficiarios distintos en 30 días |
| REM-013 | Cuenta Embudo Receptor | Receptor recibe de > 10 ordenantes distintos en 7 días |
| REM-014 | Inmediatez Disposición | Cliente recibe y envía > 80% en < 24h (48h) |

### 5.3 Modelos de Machine Learning

Actimize SAM incorpora modelos de scoring supervisado y no supervisado:

- **Modelo de Anomalía de Remesas**: Isolation Forest / Autoencoder sobre series temporales de cliente
- **Modelo de Red de Beneficiarios**: Graph Neural Network para detectar redes de cuentas embudo
- **Modelo de Perfil de Corredor**: Detección de corredores inusuales respecto a peer group

---

## 6. Flujo de Gestión de Alertas (ActOne)

```
SAM/WLF genera alerta
        │
        ▼
ActOne: Cola de alertas por severidad (CRITICAL / HIGH / MEDIUM / LOW)
        │
        ▼
Asignación automática a analista AML (round-robin / carga de trabajo)
        │
        ▼
Investigación (plazo: 30 días hábiles desde generación alerta)
        │
        ├── Falso Positivo → Cerrar con justificación → Retroalimentar modelo
        │
        └── Verdadero Positivo → Escalar a Oficial de Cumplimiento
                    │
                    ├── Operación Sospechosa → Comunicación SEPBLAC (ROS)
                    │
                    └── Operación no reportable → Cerrar con EDD adicional
```

---

## 7. Configuración de Entornos

| Entorno | Propósito | Frecuencia Carga | Fuente de Datos |
|---------|-----------|------------------|-----------------|
| **DEV** | Desarrollo y pruebas unitarias | Manual | Datos sintéticos |
| **PRE** | Pruebas de integración y UAT | Diaria (datos anonimizados) | Copia producción anonimizada |
| **PRO** | Producción | Diaria 02:00 + RT | Sistemas reales |

Los ficheros de configuración por entorno se encuentran en `/config/actimize/`.
