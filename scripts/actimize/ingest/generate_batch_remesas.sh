#!/usr/bin/env bash
# Genera el fichero batch diario de remesas para carga en NICE Actimize SAM
# Uso: ./generate_batch_remesas.sh [YYYY-MM-DD]
# Si no se pasa fecha, usa ayer (T-1)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# ── Parámetros ────────────────────────────────────────────────────────────────
TARGET_DATE="${1:-$(date -d 'yesterday' +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d)}"
ENTITY_ID="BANCOES"
OUTPUT_DIR="/tmp/actimize_batch"
BATCH_SEQ="001"

init_log "generate_batch_remesas"
log_info "Fecha objetivo: ${TARGET_DATE}"

# ── Configuración de BD fuente ────────────────────────────────────────────────
DB_HOST=$(get_config "db.host")
DB_PORT=$(get_config "db.port")
DB_NAME=$(get_config "db.name")
DB_USER=$(get_config "db.user")
DB_PASS=$(resolve_secret "$(get_config "db.password")")

SFTP_HOST=$(get_config "sftp.host")
MAX_RECORDS=$(get_config "batch.max_records_per_file")

# ── Directorio de salida ──────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"
FILENAME=$(generate_batch_filename "$ENTITY_ID" "$BATCH_SEQ")
OUTPUT_FILE="${OUTPUT_DIR}/${FILENAME}"

log_info "Fichero destino: ${OUTPUT_FILE}"

# ── Extracción de datos desde Core Banking ────────────────────────────────────
# La consulta extrae las remesas del día TARGET_DATE del core bancario.
# Se proyectan los campos en el orden del esquema del fichero batch Actimize.
# Los campos se mapean directamente desde las tablas PAYMENTS.REMITTANCE_TXN
# y PAYMENTS.CUSTOMER (join por CUSTOMER_ID del ordenante).

EXTRACT_QUERY="
SELECT
    'D' AS rec_type,
    r.TRN_ID,
    TO_CHAR(r.VALUE_DATE, 'YYYY-MM-DD'),
    TO_CHAR(r.PROCESS_DT, 'YYYY-MM-DD\"T\"HH24:MI:SS'),
    TO_CHAR(r.AMOUNT, 'FM99999999990.00'),
    r.CURRENCY,
    TO_CHAR(r.EQUIV_EUR_AMOUNT, 'FM99999999990.00'),
    'EUR',
    TO_CHAR(NVL(r.FX_RATE, 1), 'FM9990.000000'),
    -- Ordenante (Travel Rule)
    c.FULL_NAME,
    c.ACCOUNT_IBAN,
    r.SENDER_BIC,
    c.COUNTRY_CODE,
    c.ADDRESS,
    c.ID_TYPE,
    c.ID_NUMBER,
    c.INTERNAL_CIF,
    -- Beneficiario (Travel Rule)
    r.BENEFICIARY_NAME,
    r.BENEFICIARY_ACCOUNT,
    r.RECEIVER_BIC,
    r.RECEIVER_COUNTRY,
    r.RECEIVER_ADDRESS,
    -- Corresponsales
    NVL(r.INTERMEDIARY_BIC, ''),
    -- Clasificación
    r.TXN_TYPE,
    r.PURPOSE_CODE,
    r.PAYMENT_METHOD,
    r.CHANNEL,
    -- Propósito
    REPLACE(r.REMITTANCE_INFO, '|', ' '),
    r.REGULATORY_INFO,
    r.CHARGE_TYPE,
    -- gpi
    NVL(r.UETR, ''),
    -- Flags de riesgo pre-calculados
    CASE WHEN hrc.COUNTRY_CODE IS NOT NULL THEN 'Y' ELSE 'N' END AS HIGH_RISK_CTRY,
    NVL(c.PEP_FLAG, 'N'),
    NVL(r.SANCTIONS_PRE_SCREENED, 'N')
FROM
    PAYMENTS.REMITTANCE_TXN r
    JOIN PAYMENTS.CUSTOMER c ON r.SENDER_CUSTOMER_ID = c.CUSTOMER_ID
    LEFT JOIN COMPLIANCE.HIGH_RISK_COUNTRIES hrc ON r.RECEIVER_COUNTRY = hrc.COUNTRY_CODE
WHERE
    TRUNC(r.VALUE_DATE) = TO_DATE('${TARGET_DATE}', 'YYYY-MM-DD')
    AND r.STATUS = 'PROCESSED'
ORDER BY
    r.PROCESS_DT ASC
FETCH FIRST ${MAX_RECORDS} ROWS ONLY
"

log_info "Ejecutando extracción de BD: ${DB_HOST}:${DB_PORT}/${DB_NAME}"

# Contar registros antes de extraer
RECORD_COUNT=$(sqlplus -s "${DB_USER}/${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}" <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200
SELECT COUNT(*) FROM PAYMENTS.REMITTANCE_TXN
WHERE TRUNC(VALUE_DATE) = TO_DATE('${TARGET_DATE}', 'YYYY-MM-DD')
AND STATUS = 'PROCESSED';
EXIT;
EOF
)
RECORD_COUNT=$(echo "$RECORD_COUNT" | tr -d ' ')
log_info "Registros a exportar: ${RECORD_COUNT}"

if [[ "$RECORD_COUNT" -eq 0 ]]; then
    log_warn "No hay remesas para la fecha ${TARGET_DATE}. Fichero vacío no se genera."
    exit 0
fi

# Calcular suma de importes para el trailer
TOTAL_AMOUNT=$(sqlplus -s "${DB_USER}/${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}" <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200 NUMFORMAT 99999999990.00
SELECT SUM(EQUIV_EUR_AMOUNT) FROM PAYMENTS.REMITTANCE_TXN
WHERE TRUNC(VALUE_DATE) = TO_DATE('${TARGET_DATE}', 'YYYY-MM-DD')
AND STATUS = 'PROCESSED';
EXIT;
EOF
)
TOTAL_AMOUNT=$(echo "$TOTAL_AMOUNT" | tr -d ' ')

# Escribir cabecera del fichero
echo "H|${FILENAME}|$(date +%Y%m%d)|$(date +%H%M%S)|${RECORD_COUNT}|${ENTITY_ID}" > "$OUTPUT_FILE"

# Extraer registros detalle y añadir al fichero
sqlplus -s "${DB_USER}/${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}" <<EOF >> "$OUTPUT_FILE"
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 2000 COLSEP '|' TRIMSPOOL ON
${EXTRACT_QUERY};
EXIT;
EOF

# Escribir trailer
echo "T|${FILENAME}|${RECORD_COUNT}|${TOTAL_AMOUNT}" >> "$OUTPUT_FILE"

log_info "Fichero generado: $(wc -c < "$OUTPUT_FILE") bytes"

# ── Validación Travel Rule sobre muestra ─────────────────────────────────────
log_info "Validando Travel Rule en muestra de registros..."
TRAVEL_RULE_ERRORS=0
while IFS= read -r line; do
    [[ "$line" == D\|* ]] || continue
    if ! validate_travel_rule "$line"; then
        TRAVEL_RULE_ERRORS=$((TRAVEL_RULE_ERRORS + 1))
    fi
done < <(head -100 "$OUTPUT_FILE")  # muestra primeros 100 registros detalle

if [[ $TRAVEL_RULE_ERRORS -gt 0 ]]; then
    log_warn "Travel Rule: ${TRAVEL_RULE_ERRORS} registros con campos incompletos (muestra 100)"
fi

# ── Cifrado PGP ───────────────────────────────────────────────────────────────
ENCRYPTED_FILE="${OUTPUT_FILE}.gpg"
log_info "Cifrando fichero con PGP..."
gpg --batch --yes \
    --recipient "actimize-ingest@bancoes.es" \
    --output "$ENCRYPTED_FILE" \
    --encrypt "$OUTPUT_FILE"

# Eliminar fichero sin cifrar inmediatamente tras el cifrado
rm -f "$OUTPUT_FILE"
log_ok "Fichero cifrado: ${ENCRYPTED_FILE}"

# ── Compresión ────────────────────────────────────────────────────────────────
COMPRESSED_FILE="${ENCRYPTED_FILE}.gz"
gzip -c "$ENCRYPTED_FILE" > "$COMPRESSED_FILE"
rm -f "$ENCRYPTED_FILE"
log_ok "Fichero comprimido: ${COMPRESSED_FILE}"

# ── Envío SFTP ────────────────────────────────────────────────────────────────
log_info "Enviando fichero a Actimize SFTP: ${SFTP_HOST}"
if sftp_upload "$COMPRESSED_FILE"; then
    log_ok "Fichero enviado correctamente a Actimize"
    # Archivar localmente
    ARCHIVE_DIR="${OUTPUT_DIR}/archive/$(date +%Y%m)"
    mkdir -p "$ARCHIVE_DIR"
    mv "$COMPRESSED_FILE" "${ARCHIVE_DIR}/"
    log_info "Fichero archivado en: ${ARCHIVE_DIR}"
else
    log_error "Fallo en envío SFTP. El fichero queda en: ${COMPRESSED_FILE}"
    exit 1
fi

log_ok "Proceso completado: ${RECORD_COUNT} remesas del ${TARGET_DATE} enviadas a Actimize"
