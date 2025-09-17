#!/usr/bin/env bash

set -euo pipefail

# standardized logging helpers (mirrors setup.sh style)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
  local color=$1
  local level=$2
  local emoticon=$3
  local message=$4
  printf "${color}[%s] %s %s: %s${NC}\n" "$(date +'%H:%M:%S')" "$emoticon" "$level" "$message"
}

log_info() { log "${CYAN}" "INFO" "ℹ️" "$1"; }
log_success() { log "${GREEN}" "SUCCESS" "✅" "$1"; }
log_warn() { log "${YELLOW}" "WARNING" "⚠️" "$1"; }
log_error() { log "${RED}" "ERROR" "❌" "$1"; }
log_output() { printf "%s\n" "$1"; }

executeCommand() {
  local description=$1
  local command_to_run=$2
  local success_message=$3
  local failure_message=$4

  log_info "Starting: ${description}"

  local output exit_code
  if ! output=$(eval "$command_to_run" 2>&1); then
    exit_code=$?
    log_error "${description} failed with exit code ${exit_code}."
    log_error "Details: ${failure_message}"
    echo -e "${RED}--- Command Output (STDERR) ---"
    log_output "$output"
    echo "-----------------------------------${NC}"
    return 1
  fi

  log_success "${description}: ${success_message}"
  return 0
}

ensure_repo_owner() {
  local root_dir=$1
  local owner
  owner=$(stat -c '%U' "$root_dir")
  local current
  current=$(id -un)

  if [[ ${owner} != ${current} ]]; then
    log_error "Run this script as the repository owner (${owner}). Current user: ${current}."
    exit 1
  fi
}

backup_env() {
  if [[ -f .env ]]; then
    executeCommand "Backing up existing .env" "cp .env .env.bak" "Backup created (.env.bak)" "Unable to copy .env to .env.bak"
  else
    log_warn ".env not found. Backup skipped."
  fi
}

restore_values() {
  if [[ ! -f .env.bak ]]; then
    log_warn ".env.bak not found. Import skipped."
    return
  fi

  log_info "Restoring preserved values from .env.bak"
  while IFS= read -r line; do
    [[ $line =~ ^[a-zA-Z_][a-zA-Z0-9_]*= ]] || continue

    local variable_name variable_value
    variable_name=${line%%=*}
    variable_value=${line#*=}

    if [[ -n ${variable_value} && -f .env ]] && grep -q "^${variable_name}=" .env; then
      log_info "Updating ${variable_name}"
      sed -i "s|^${variable_name}=.*|${variable_name}=${variable_value}|" .env
    fi
  done < .env.bak
}

main() {
  local script_dir root_dir owner service
  script_dir=$(dirname "$(readlink -f "$0")")
  owner=$(stat -c '%U' "$script_dir")
  root_dir=$(sudo -u "$owner" git -C "$script_dir" rev-parse --show-toplevel)
  service=$(basename "$root_dir")

  log_info "Updating env file for ${service}"
  ensure_repo_owner "$root_dir"

  executeCommand "Changing directory to repo root" "cd '$root_dir'" "In repo root" "Unable to change to repo root"

  backup_env

  if [[ ! -f .env.example ]]; then
    log_error ".env.example not found in ${root_dir}"
    exit 1
  fi

  executeCommand "Refreshing .env from template" "cp .env.example .env" ".env replaced" "Unable to copy .env.example to .env"

  restore_values

  executeCommand "Setting ownership on .env" "chown $(stat -c '%U' .): $(pwd)/.env" "Ownership updated" "Unable to chown .env"

  log_success "Environment file update complete"
}

main "$@"
