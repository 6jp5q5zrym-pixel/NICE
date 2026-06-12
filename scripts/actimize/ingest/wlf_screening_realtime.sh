#!/usr/bin/env bash
# Screening WLF en tiempo real contra Actimize para una remesa individual
# Uso: ./wlf_screening_realtime.sh <json_payload_file>
# Retorna: 0=CLEAR, 1=HIT, 2=ERROR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

PAYLOAD_FILE="${1:?Uso: $0 <json_payload_file>}"
[[ -f "$PAYLOAD_FILE" ]] || { log_error "Fichero no encontrado: ${PAYLOAD_FILE}"; exit 2; }

init_log "wlf_screening"

API_BASE=$(get_config "actimize.api.base_url")
CLIENT_ID=$(get_config "actimize.api.client_id")
API_SECRET=$(resolve_secret "$(get_config "actimize.api.secret")")
SLA_MS=$(get_config "sla.wlf_realtime_ms")
SLA_S=$(( (SLA_MS + 999) / 1000 ))

CORRELATION_ID="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"

log_info "Screening WLF | correlationId=${CORRELATION_ID} | payload=${PAYLOAD_FILE}"

# ── Obtener JWT ───────────────────────────────────────────────────────────────
JWT_TOKEN=$(curl -sf \
    --max-time 5 \
    -X POST "${API_BASE}/auth/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=${CLIENT_ID}&client_secret=${API_SECRET}&grant_type=client_credentials" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null)

if [[ -z "$JWT_TOKEN" ]]; then
    log_error "No se pudo obtener JWT de Actimize"
    exit 2
fi

# ── Llamada al endpoint de screening ─────────────────────────────────────────
START_TS=$(date +%s%3N)

RESPONSE=$(curl -sf \
    --max-time "$SLA_S" \
    -X POST "${API_BASE}/screening/realtime" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${JWT_TOKEN}" \
    -H "X-Actimize-Client-ID: ${CLIENT_ID}" \
    -H "X-Correlation-ID: ${CORRELATION_ID}" \
    --data-binary "@${PAYLOAD_FILE}" 2>&1)

CURL_EXIT=$?
END_TS=$(date +%s%3N)
ELAPSED_MS=$(( END_TS - START_TS ))

if [[ $CURL_EXIT -ne 0 ]]; then
    log_error "Error HTTP en screening WLF (curl_exit=${CURL_EXIT}, elapsed=${ELAPSED_MS}ms)"
    exit 2
fi

log_info "Respuesta recibida en ${ELAPSED_MS}ms"

# ── Parsear respuesta ─────────────────────────────────────────────────────────
SCREENING_STATUS=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','UNKNOWN'))" 2>/dev/null)
HIT_COUNT=$(echo "$RESPONSE" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('hits',[])))" 2>/dev/null || echo 0)

log_info "Resultado WLF: status=${SCREENING_STATUS} | hits=${HIT_COUNT} | correlationId=${CORRELATION_ID}"

case "$SCREENING_STATUS" in
    CLEAR)
        log_ok "CLEAR — Sin hits en listas de sanciones/PEP"
        exit 0
        ;;
    HIT)
        log_warn "HIT — ${HIT_COUNT} coincidencia(s) detectada(s). Operación bloqueada para revisión."
        # Registrar hits para el analista
        echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for h in data.get('hits', []):
    print(f\"  Lista: {h.get('listName')} | Entidad: {h.get('matchedEntity')} | Score: {h.get('matchScore')}% | Tipo: {h.get('matchType')}\")
" 2>/dev/null | while read -r line; do log_warn "$line"; done
        exit 1
        ;;
    REVIEW)
        log_warn "REVIEW — Requiere revisión manual. Posibles hits de baja confianza."
        exit 1
        ;;
    *)
        log_error "Estado de screening desconocido: ${SCREENING_STATUS}"
        exit 2
        ;;
esac
