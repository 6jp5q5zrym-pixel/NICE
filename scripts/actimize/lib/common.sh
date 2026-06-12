#!/usr/bin/env bash
# Funciones compartidas para scripts de integración Actimize — módulo Remesas

set -euo pipefail

# ── Variables de entorno requeridas ──────────────────────────────────────────
: "${ACTIMIZE_ENV:?ACTIMIZE_ENV no definido (dev|pre|pro)}"
: "${CONFIG_FILE:=/home/user/NICE/config/actimize/environments.conf}"
: "${LOG_DIR:=/var/log/actimize/remesas}"
: "${SCRIPT_NAME:=$(basename "$0")}"

# ── Colores para logs en consola ─────────────────────────────────────────────
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'

# ── Logging ──────────────────────────────────────────────────────────────────
log_info()  { echo -e "$(date -u +%Y-%m-%dT%H:%M:%SZ) [INFO]  ${SCRIPT_NAME}: $*" | tee -a "${LOG_FILE:-/dev/null}"; }
log_warn()  { echo -e "$(date -u +%Y-%m-%dT%H:%M:%SZ) ${YELLOW}[WARN]${NC}  ${SCRIPT_NAME}: $*" | tee -a "${LOG_FILE:-/dev/null}"; }
log_error() { echo -e "$(date -u +%Y-%m-%dT%H:%M:%SZ) ${RED}[ERROR]${NC} ${SCRIPT_NAME}: $*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
log_ok()    { echo -e "$(date -u +%Y-%m-%dT%H:%M:%SZ) ${GREEN}[OK]${NC}    ${SCRIPT_NAME}: $*" | tee -a "${LOG_FILE:-/dev/null}"; }

# ── Leer configuración por entorno ───────────────────────────────────────────
get_config() {
    local key="$1"
    local env="${ACTIMIZE_ENV}"
    local in_section=0
    local value=""

    while IFS='=' read -r k v; do
        [[ "$k" =~ ^\[(.+)\]$ ]] && { [[ "${BASH_REMATCH[1]}" == "$env" ]] && in_section=1 || in_section=0; continue; }
        [[ $in_section -eq 1 && "$k" == "$key" ]] && { value="${v}"; break; }
    done < "$CONFIG_FILE"

    echo "$value"
}

# ── Resolución de secretos desde Vault ───────────────────────────────────────
resolve_secret() {
    local value="$1"
    if [[ "$value" == \${VAULT:*} ]]; then
        local vault_path="${value#\${VAULT:}"
        vault_path="${vault_path%\}}"
        vault kv get -field=value "secret/${vault_path}" 2>/dev/null || {
            log_error "No se pudo resolver secreto Vault: ${vault_path}"
            return 1
        }
    else
        echo "$value"
    fi
}

# ── Inicializar log del script ────────────────────────────────────────────────
init_log() {
    local log_name="${1:-${SCRIPT_NAME%.sh}}"
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/${log_name}_$(date +%Y%m%d).log"
    export LOG_FILE
    log_info "=== Inicio ejecución | entorno=${ACTIMIZE_ENV} | PID=$$ ==="
}

# ── Generar nombre de fichero batch ──────────────────────────────────────────
generate_batch_filename() {
    local entity="${1:-BANCOES}"
    local seq="${2:-001}"
    echo "REMESAS_${entity}_$(date +%Y%m%d)_$(date +%H%M%S)_${seq}.dat"
}

# ── Calcular hash SHA256 de un fichero ────────────────────────────────────────
file_sha256() {
    sha256sum "$1" | awk '{print $1}'
}

# ── Envío por SFTP con reintentos ─────────────────────────────────────────────
sftp_upload() {
    local local_file="$1"
    local remote_dir
    remote_dir=$(get_config "sftp.remote_path")
    local sftp_host sftp_port sftp_user sftp_key
    sftp_host=$(get_config "sftp.host")
    sftp_port=$(get_config "sftp.port")
    sftp_user=$(get_config "sftp.user")
    sftp_key=$(get_config "sftp.key_path")

    local filename; filename=$(basename "$local_file")
    local ctrl_file="${local_file%.dat}.ctrl"

    # Generar fichero de control
    {
        echo "FILENAME=${filename}"
        echo "SHA256=$(file_sha256 "$local_file")"
        echo "RECORDS=$(grep -c '^D|' "$local_file" || echo 0)"
        echo "TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$ctrl_file"

    local attempt=0
    local max_retries=4
    local delay=2

    while [[ $attempt -lt $max_retries ]]; do
        attempt=$((attempt + 1))
        log_info "SFTP upload intento ${attempt}/${max_retries}: ${filename} → ${sftp_host}:${remote_dir}"

        if sftp -i "$sftp_key" -P "$sftp_port" -o BatchMode=yes -o ConnectTimeout=30 \
                "${sftp_user}@${sftp_host}" <<EOF
put ${local_file} ${remote_dir}${filename}.tmp
put ${ctrl_file} ${remote_dir}$(basename "${ctrl_file}")
rename ${remote_dir}${filename}.tmp ${remote_dir}${filename}
EOF
        then
            log_ok "SFTP upload completado: ${filename}"
            return 0
        fi

        log_warn "SFTP upload fallido (intento ${attempt}). Reintentando en ${delay}s..."
        sleep "$delay"
        delay=$((delay * 2))
    done

    log_error "SFTP upload fallido tras ${max_retries} intentos: ${filename}"
    return 1
}

# ── Validar campos Travel Rule en un registro CSV ────────────────────────────
validate_travel_rule() {
    local record="$1"
    IFS='|' read -ra fields <<< "$record"

    local originator_name="${fields[8]:-}"
    local originator_account="${fields[9]:-}"
    local originator_country="${fields[12]:-}"
    local beneficiary_name="${fields[18]:-}"
    local beneficiary_account="${fields[19]:-}"

    local valid=1
    [[ -z "$originator_name" ]]    && { log_warn "Travel Rule: falta originator_name"; valid=0; }
    [[ -z "$originator_account" ]] && { log_warn "Travel Rule: falta originator_account"; valid=0; }
    [[ -z "$originator_country" ]] && { log_warn "Travel Rule: falta originator_country"; valid=0; }
    [[ -z "$beneficiary_name" ]]   && { log_warn "Travel Rule: falta beneficiary_name"; valid=0; }
    [[ -z "$beneficiary_account" ]] && { log_warn "Travel Rule: falta beneficiary_account"; valid=0; }

    return $((1 - valid))
}

# ── Notificación de error (email / Slack) ────────────────────────────────────
notify_error() {
    local subject="$1"
    local body="$2"
    local alert_email
    alert_email=$(get_config "monitoring.alert_email")

    if [[ -n "$alert_email" ]]; then
        echo "$body" | mail -s "[ACTIMIZE][${ACTIMIZE_ENV^^}] ERROR: ${subject}" "$alert_email" 2>/dev/null || true
    fi
    log_error "NOTIFICACIÓN: ${subject} — ${body}"
}

# ── Cleanup al salir ─────────────────────────────────────────────────────────
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script terminó con código ${exit_code}"
        notify_error "Fallo en ${SCRIPT_NAME}" "exit_code=${exit_code} | entorno=${ACTIMIZE_ENV} | log=${LOG_FILE:-N/A}"
    else
        log_info "=== Fin ejecución correcta | duración=$((SECONDS))s ==="
    fi
}

trap cleanup EXIT
