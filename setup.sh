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

write_secret_file() {
    local var_name=$1
    local target_file=$2
    local mode=$3

    require_var "$var_name"
    local value=${!var_name}

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

    mkdir -p "$(dirname "$target")"
    envsubst < "$template" > "$target"
}

main() {
    ensure_repo_owner
    source_env

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

    for var in LOKI_GCS_BUCKET MIMIR_BLOCKS_BUCKET MIMIR_RULER_BUCKET; do
        executeCommand \
            "Validating $var" \
            "require_var $var" \
            "$var is set" \
            "Populate $var in your .env file."
    done

    executeCommand \
        "Writing Loki service account" \
        "write_secret_file LOKI_GCS_SERVICE_ACCOUNT_JSON_B64 '${ROOT_DIR}/loki/gcs-service-account.json' base64" \
        "Loki credentials written" \
        "Populate LOKI_GCS_SERVICE_ACCOUNT_JSON_B64 with base64 encoded JSON."

    executeCommand \
        "Writing Mimir service account" \
        "write_secret_file MIMIR_GCS_SERVICE_ACCOUNT_JSON_B64 '${ROOT_DIR}/mimir/gcs-service-account.json' base64" \
        "Mimir credentials written" \
        "Populate MIMIR_GCS_SERVICE_ACCOUNT_JSON_B64 with base64 encoded JSON."

    executeCommand \
        "Writing Alertmanager webhook" \
        "write_secret_file ALERTMANAGER_GOOGLE_CHAT_WEBHOOK_URL '${ROOT_DIR}/alertmanager/google-chat-webhook.url' text" \
        "Alertmanager webhook written" \
        "Populate ALERTMANAGER_GOOGLE_CHAT_WEBHOOK_URL with your Google Chat webhook URL."

    local templates=(
        "${ROOT_DIR}/traefik/docker-compose.yml.example:${ROOT_DIR}/traefik/docker-compose.yml"
        "${ROOT_DIR}/grafana/docker-compose.yml.example:${ROOT_DIR}/grafana/docker-compose.yml"
        "${ROOT_DIR}/loki/docker-compose.yml.example:${ROOT_DIR}/loki/docker-compose.yml"
        "${ROOT_DIR}/mimir/docker-compose.yml.example:${ROOT_DIR}/mimir/docker-compose.yml"
        "${ROOT_DIR}/alertmanager/docker-compose.yml.example:${ROOT_DIR}/alertmanager/docker-compose.yml"
        "${ROOT_DIR}/alloy/docker-compose.yml.example:${ROOT_DIR}/alloy/docker-compose.yml"
        "${ROOT_DIR}/loki/config.yaml.example:${ROOT_DIR}/loki/config.yaml"
        "${ROOT_DIR}/mimir/config.yaml.example:${ROOT_DIR}/mimir/config.yaml"
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
