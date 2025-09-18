#!/usr/bin/env bash

set -euo pipefail

# --- Color Variables ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Core Logging Function ---
log() {
    local color=$1
    local level=$2
    local emoticon=$3
    local message=$4
    printf "${color}[%s] %s %s: %s${NC}\n" "$(date +'%H:%M:%S')" "$emoticon" "$level" "$message"
}

log_info() {
    log "${CYAN}" "INFO" "ℹ️" "$1"
}

log_success() {
    log "${GREEN}" "SUCCESS" "✅" "$1"
}

log_warn() {
    log "${YELLOW}" "WARNING" "⚠️" "$1"
}

log_error() {
    log "${RED}" "ERROR" "❌" "$1"
}

log_output() {
    printf "%s\n" "$1"
}

backup_file() {
    local file_to_backup=$1
    if [[ -f "$file_to_backup" ]]; then
        local timestamp=$(date +"%Y%m%d%H%M%S")
        local backup_dir=$(dirname "$file_to_backup")
        local filename=$(basename "$file_to_backup")
        local backup_file="${backup_dir}/${filename}.${timestamp}.bak"
        log_warn "Backing up existing file: $file_to_backup to $backup_file"
        mv "$file_to_backup" "$backup_file"
    fi
}

executeCommand() {
    local description=$1
    local command_to_run=$2
    local success_message=$3
    local failure_message=$4

    log_info "Starting: $description"

    local output
    local exit_code

    if ! output=$(eval "$command_to_run" 2>&1); then
        exit_code=$?
        log_error "$description failed with exit code $exit_code."
        log_error "Details: $failure_message"
        echo -e "${RED}--- Command Output (STDERR) ---"
        log_output "$output"
        echo "-----------------------------------${NC}"
        return 1
    fi

    log_success "$description: $success_message"
    return 0
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
    log_error "Missing .env file at ${ENV_FILE}. Copy .env.example and populate required secrets."
    exit 1
fi

source_env() {
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
}

require_var() {
    local var_name=$1
    local value=${!var_name-}

    if [[ -z ${value} ]]; then
        echo "${var_name} is empty"
        return 1
    fi

    if [[ ${value} == ENTER_* || ${value} == REPLACE_* ]]; then
        echo "${var_name} still set to placeholder (${value})"
        return 1
    fi
}

ensure_repo_owner() {
    local owner
    owner=$(stat -c '%U' "${ROOT_DIR}")
    local current
    current=$(id -un)

    if [[ ${owner} != ${current} ]]; then
        log_error "This script must be run as the repository owner (${owner}). Current user: ${current}."
        exit 1
    fi
}

generate_alloy_log_sources() {
    local raw="${ALLOY_FILE_LOG_PATHS-}"
    if [[ -z ${raw} ]]; then
        raw="/var/log/*log"
    fi

    local idx=0
    IFS=',' read -r -a paths <<< "${raw}"
    for path in "${paths[@]}"; do
        local trimmed
        trimmed=$(printf '%s' "$path" | xargs)
        if [[ -z ${trimmed} ]]; then
            continue
        fi

        local sanitized=${trimmed//[^a-zA-Z0-9]/_}
        sanitized=${sanitized##_}
        sanitized=${sanitized%%_}
        sanitized=${sanitized,,}
        if [[ -z ${sanitized} ]]; then
            sanitized="log"
        fi
        local name="${sanitized}_${idx}"

        printf 'loki.source.file "%s" {
' "${name}"
        printf '  targets    = [
'
        printf '    {__path__ = "%s", host = env("ALLOY_HOSTNAME"), job = "%s"},
' "${trimmed}" "${name}"
        printf '  ]
'
        printf '  forward_to = [loki.write.loki_sink.receiver]
'
        printf '}

'

        ((idx++))
    done

    if [[ ${idx} -eq 0 ]]; then
        printf 'loki.source.file "varlogs_0" {
'
        printf '  targets    = [
'
        printf '    {__path__ = "/var/log/*log", host = env("ALLOY_HOSTNAME"), job = "varlogs_0"},
'
        printf '  ]
'
        printf '  forward_to = [loki.write.loki_sink.receiver]
'
        printf '}

'
    fi
}

write_secret_file() {
    local var_name=$1
    local target_file=$2
    local mode=$3

    require_var "$var_name"
    local value=${!var_name}

    backup_file "$target_file"
    mkdir -p "$(dirname "$target_file")"

    if [[ "$mode" == "base64" ]]; then
        echo "$value" | base64 --decode > "$target_file"
    else
        printf "%s\n" "$value" > "$target_file"
    fi
    chmod 600 "$target_file"
}

render_template() {
    local template=$1
    local target=$2

    if [[ ! -f "$template" ]]; then
        log_error "Template $template not found."
        return 1
    fi

    backup_file "$target"
    mkdir -p "$(dirname "$target")"
    envsubst < "$template" > "$target"
}

main() {
    ensure_repo_owner
    source_env

    export ALLOY_LOG_SOURCES="$(generate_alloy_log_sources)"

    executeCommand \
        "Verifying base64 availability" \
        "command -v base64" \
        "base64 command is available" \
        "Install coreutils/base64 to continue." || exit 1

    executeCommand \
        "Verifying envsubst availability" \
        "command -v envsubst" \
        "envsubst command is available" \
        "Install gettext (envsubst) to continue." || exit 1

    for var in LOKI_GCS_BUCKET MIMIR_BLOCKS_BUCKET MIMIR_RULER_BUCKET \
               GRAFANA_ADMIN_PASSWORD GRAFANA_DOMAIN \
               GRAFANA_DB_HOST GRAFANA_DB_NAME GRAFANA_DB_USER GRAFANA_DB_PASSWORD \
               TRAEFIK_ACME_EMAIL; do
        executeCommand \
            "Validating $var" \
            "require_var $var" \
            "$var is set" \
            "Populate $var in your .env file."
    done

    # Decode Mimir GCS Service Account JSON and indent for YAML block scalars
    # This preserves pretty JSON inside:
    # common:
    #   storage:
    #     gcs:
    #       service_account: |
    #         {\n          "type": ... }
    if require_var "MIMIR_GCS_SERVICE_ACCOUNT_JSON_B64"; then
        # Decode JSON and indent: 10 spaces for all lines except the last, which gets 8.
        # This matches YAML expectation under:
        #   service_account: |
        #     ... (10 spaces)
        #   (closing brace) (8 spaces)
        export MIMIR_GCS_SERVICE_ACCOUNT_JSON_DECODED=$(echo "${MIMIR_GCS_SERVICE_ACCOUNT_JSON_B64}" \
            | base64 --decode \
            | awk '{ lines[NR] = $0 } END { \
                if (NR == 1) { \
                    # Single-line JSON: emit as-is (no extra indent) because YAML already provides 8 spaces
                    printf "%s\n", lines[1]; \
                    exit \
                } \
                # Multi-line: first line no extra indent (opening brace already at 8 via YAML), \
                # middle lines get 10 spaces, last line no extra indent
                printf "%s\n", lines[1]; \
                for (i = 2; i < NR; i++) printf "          %s\n", lines[i]; \
                printf "        %s\n", lines[NR]; \
            }')
    else
        log_error "MIMIR_GCS_SERVICE_ACCOUNT_JSON_B64 is not set or is a placeholder. Mimir config will not have GCS service account."
        # Export an empty string or a placeholder if it's not set, to avoid errors during envsubst
        export MIMIR_GCS_SERVICE_ACCOUNT_JSON_DECODED=""
    fi

    executeCommand \
        "Writing Loki service account" \
        "write_secret_file LOKI_GCS_SERVICE_ACCOUNT_JSON_B64 '${ROOT_DIR}/loki/gcs-service-account.json' base64" \
        "Loki credentials written" \
        "Populate LOKI_GCS_SERVICE_ACCOUNT_JSON_B64 with base64 encoded JSON."

    executeCommand \
        "Writing Alertmanager webhook" \
        "write_secret_file ALERTMANAGER_GOOGLE_CHAT_WEBHOOK_URL '${ROOT_DIR}/alertmanager/google-chat-webhook.url' text" \
        "Alertmanager webhook written" \
        "Populate ALERTMANAGER_GOOGLE_CHAT_WEBHOOK_URL with your Google Chat webhook URL."

    export MIMIR_CONFIG_FILE="${ROOT_DIR}/mimir/config.yaml"
    export MIMIR_SWARM_CONFIG_NAME="mimir-config" # New: Export dynamic Swarm config name

    local templates=(
        "${ROOT_DIR}/traefik/docker-compose.yml.example:${ROOT_DIR}/traefik/docker-compose.yml"
        "${ROOT_DIR}/grafana/docker-compose.yml.example:${ROOT_DIR}/grafana/docker-compose.yml"
        "${ROOT_DIR}/loki/docker-compose.yml.example:${ROOT_DIR}/loki/docker-compose.yml"
        "${ROOT_DIR}/mimir/docker-compose.yml.example:${ROOT_DIR}/mimir/docker-compose.yml"
        "${ROOT_DIR}/alertmanager/docker-compose.yml.example:${ROOT_DIR}/alertmanager/docker-compose.yml"
        "${ROOT_DIR}/alloy/docker-compose.yml.example:${ROOT_DIR}/alloy/docker-compose.yml"
        "${ROOT_DIR}/alloy/config.alloy.example:${ROOT_DIR}/alloy/config.alloy"
        "${ROOT_DIR}/loki/config.yaml.example:${ROOT_DIR}/loki/config.yaml"
        "${ROOT_DIR}/grafana/provisioning/datasources/datasources.yaml.example:${ROOT_DIR}/grafana/provisioning/datasources/datasources.yaml"
        "${ROOT_DIR}/mimir/config.yaml.example:${MIMIR_CONFIG_FILE}"
    )

    for pair in "${templates[@]}"; do
        IFS=":" read -r template target <<< "$pair"
        executeCommand \
            "Rendering $(basename "$target")" \
            "render_template '$template' '$target'" \
            "Rendered $(basename "$target")" \
            "Failed to render $target"
    done

    log_success "Secrets and compose files materialized successfully."
}

main "$@"
