# Flujo de Pagos por Remesas: Marco Técnico y Regulatorio

## 1. Definición y Tipología de Remesas

Una **remesa** es una transferencia internacional de fondos enviada, generalmente, por un trabajador migrante a su país de origen. En el contexto bancario y de compliance, las remesas presentan características diferenciales respecto a otras transferencias internacionales:

- Importes unitarios relativamente pequeños (típicamente < 5.000 €)
- Alta frecuencia y regularidad (mensual/quincenal)
- Corredor geográfico definido (ej: España → Latinoamérica, España → Marruecos)
- Remitente persona física residente, beneficiario en país de riesgo elevado

### Tipos de operativa de remesas

| Tipo | Descripción | Ejemplos |
|------|-------------|---------|
| **Transferencia bancaria** | Canal SWIFT o SEPA entre entidades | Wire transfer MT103, SEPA SCT |
| **Operador de Remesas (MTO)** | Entidad especializada, no bancaria | Western Union, MoneyGram, Wise |
| **Hawala / Hundi** | Sistema informal de valor sin movimiento físico | Redes informales (alto riesgo AML) |
| **Criptoactivos** | Transferencias P2P blockchain | Bitcoin, USDT (VASP) |
| **Efectivo** | Entrega física en destino | Correos, oficinas MTO |

---

## 2. Estándares de Mensajería

### 2.1 SWIFT MT103 – Single Customer Credit Transfer

Mensaje SWIFT utilizado para transferencias de cliente a cliente entre bancos corresponsales.

**Campos relevantes para AML:**

```
:20:  REFERENCIA DE TRANSACCIÓN (TRN)
:23B: CÓDIGO DE TIPO DE BANCO (CRED)
:32A: FECHA VALOR / DIVISA / IMPORTE
:50K: ORDENANTE (nombre + dirección o cuenta)
      /ES1234567890123456789012
      JUAN GARCIA LOPEZ
      C/MAYOR 15, MADRID, ESPAÑA
:52A: BANCO ORDENANTE (BIC)
:56A: BANCO INTERMEDIARIO (corresponsal)
:57A: BANCO BENEFICIARIO (BIC)
:59:  BENEFICIARIO (nombre + cuenta)
      /MX123456789012345678
      MARIA GARCIA
      AV. REFORMA 100, CDMX, MEXICO
:70:  CONCEPTO / PROPÓSITO
      REMESA FAMILIAR
:71A: COMISIONES (OUR/BEN/SHA)
:77B: INFORMACIÓN REGULATORIA
      /ORDERRES/            (país residencia ordenante)
      /BENEFRES/            (país residencia beneficiario)
```

### 2.2 ISO 20022 – pacs.008 (FI to FI Customer Credit Transfer)

Nuevo estándar obligatorio en la red SWIFT a partir de noviembre 2025 (coexistencia con MT hasta 2025, migración completa prevista).

**Estructura XML simplificada:**
```xml
<Document>
  <FIToFICstmrCdtTrf>
    <GrpHdr>
      <MsgId>MSG20240612001</MsgId>
      <CreDtTm>2024-06-12T09:00:00</CreDtTm>
      <NbOfTxs>1</NbOfTxs>
      <SttlmInf><SttlmMtd>CLRG</SttlmMtd></SttlmInf>
    </GrpHdr>
    <CdtTrfTxInf>
      <PmtId>
        <EndToEndId>E2E-REF-001</EndToEndId>
        <UETR>550e8400-e29b-41d4-a716-446655440000</UETR>
      </PmtId>
      <IntrBkSttlmAmt Ccy="EUR">850.00</IntrBkSttlmAmt>
      <Dbtr>
        <Nm>JUAN GARCIA LOPEZ</Nm>
        <PstlAdr><Ctry>ES</Ctry></PstlAdr>
      </Dbtr>
      <DbtrAcct><Id><IBAN>ES1234567890123456789012</IBAN></Id></DbtrAcct>
      <CdtrAgt><FinInstnId><BIC>BBVAMXMMXXX</BIC></FinInstnId></CdtrAgt>
      <Cdtr>
        <Nm>MARIA GARCIA</Nm>
        <PstlAdr><Ctry>MX</Ctry></PstlAdr>
      </Cdtr>
      <CdtrAcct><Id><Othr><Id>MX123456789012345678</Id></Othr></Id></CdtrAcct>
      <Purp><Cd>FAMI</Cd></Purp>  <!-- Remesa familiar -->
    </CdtTrfTxInf>
  </FIToFICstmrCdtTrf>
</Document>
```

### 2.3 SWIFT gpi (Global Payments Innovation)

Capa de trazabilidad sobre MT103/pacs.008 que añade:
- **UETR** (Unique End-to-end Transaction Reference): UUID v4 inmutable
- **Tracker**: seguimiento en tiempo real del estado del pago
- **g4C** (gpi for Corporates): integración con ERPs corporativos

### 2.4 SEPA Credit Transfer (SCT / SCT Inst)

Para remesas dentro del Área SEPA (limitado a países adheridos):
- Estándar: `pain.001` (iniciación) → `pacs.008` (interbank) → `pacs.002` (confirmación)
- SCT: liquidación D+1 | SCT Inst: liquidación en < 10 segundos

---

## 3. Cadena de Banca Corresponsal

```
[ORDENANTE] → [BANCO ORDENANTE] → [CORRESPONSAL 1] → [CORRESPONSAL N] → [BANCO BENEFICIARIO] → [BENEFICIARIO]
   Cliente        (Originating         (Intermediary        (Intermediary      (Receiving Bank)      Cliente
                    Bank)                  Bank)                Bank)
```

### Roles y responsabilidades AML:

| Rol | Responsabilidad AML |
|-----|---------------------|
| **Originating Bank** | KYC completo del ordenante, screening inicial, Travel Rule |
| **Intermediary Bank** | Screening contra listas de sanciones, monitorización de patrones |
| **Receiving Bank** | KYC del beneficiario, screening final, reporte si detecta anomalía |

### Riesgo de opacidad en cadenas largas

Las cadenas con > 2 corresponsales incrementan el riesgo de:
- Pérdida de información del ordenante original (campo :50K truncado)
- Imposibilidad de screening completo por datos incompletos
- Nested correspondent banking (corresponsal dentro de corresponsal)

---

## 4. Marco Regulatorio Aplicable

### 4.1 FATF Recomendación 16 – Regla de Viaje (Travel Rule)

Obliga a transmitir información del ordenante y beneficiario a lo largo de toda la cadena de pago:

**Información requerida del ORDENANTE:**
- Nombre completo
- Número de cuenta (IBAN/BBAN)
- Dirección física O número de documento nacional de identidad O fecha/lugar de nacimiento O número de cliente

**Información requerida del BENEFICIARIO:**
- Nombre completo
- Número de cuenta (IBAN/BBAN)

**Umbral:** Todas las transferencias (sin umbral mínimo en UE desde 2027 con TFR Reglamento 2023/1113).

### 4.2 Reglamento (UE) 2023/1113 – Transfer of Funds Regulation (TFR)

Sustituyó al Reglamento 847/2015. Principales novedades:
- Extensión de Travel Rule a **criptoactivos** (PSPs y CASPs)
- Sin umbral mínimo (antes era 1.000 €)
- Obligación de verificar beneficiario antes de acreditar
- Plazo de retención de datos: **5 años**

### 4.3 Directivas AML de la UE

| Directiva | Aspectos Clave |
|-----------|----------------|
| **4AMLD** (2015/849) | Enfoque basado en riesgo, UBOs, registros de titulares reales |
| **5AMLD** (2018/843) | Criptomonedas, tarjetas prepago, registros UBO públicos |
| **6AMLD** (2018/1673) | 22 delitos previos, responsabilidad penal personas jurídicas |
| **AML Package 2024** | Nueva Autoridad AML de la UE (AMLA), AMLR directamente aplicable |

### 4.4 Normativa Española

- **Ley 10/2010** de prevención del blanqueo de capitales
- **RD 304/2014** Reglamento de desarrollo
- **Circular SEPBLAC** sobre medidas de diligencia debida reforzada en remesas
- **Umbral de declaración** al Banco de España: > 50.000 € (transferencias al exterior)

---

## 5. Tipologías de Riesgo en Remesas

### 5.1 Estructuración (Smurfing)
- Múltiples envíos de pequeño importe por debajo del umbral de declaración
- Mismo beneficiario o destino geográfico
- Señal: patrón de importes ligeramente por debajo de 1.000 € / 3.000 € / 10.000 €

### 5.2 Cuentas Embudo (Funnel Accounts)
- Cuenta receptora de múltiples ingresos de diferentes ordenantes
- Inmediata salida de fondos (< 24h) hacia un único destino
- Señal: ratio depósitos/disposiciones > 0.9, tiempo medio de permanencia < 1 día

### 5.3 Uso de Terceros / Testaferros
- Fondos enviados por persona distinta al origen económico real
- Señal: múltiples clientes enviando al mismo beneficiario sin relación aparente

### 5.4 Actividad Inconsistente con el Perfil
- Importes o frecuencia incompatibles con capacidad económica declarada
- Señal: salidas > 150% de ingresos mensuales declarados en período acumulado

### 5.5 Corredores de Alto Riesgo
- Países con deficiencias FATF (lista gris/negra)
- Jurisdicciones con secreto bancario o baja supervisión AML
- Señal: > X% del volumen mensual hacia países FATF lista gris

### 5.6 Blanqueo Basado en Comercio (TBML)
- Sobre/infravaloración de facturas en operaciones de importación/exportación
- Remesas enmascaradas como pagos comerciales
- Señal: propósito "TRADE" + beneficiario en paraíso fiscal + importe redondo
