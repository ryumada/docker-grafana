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
    printf "%s\n" "$output"
    echo "-----------------------------------${NC}"
    return 1
  fi

  log_success "${description}: ${success_message}"
  return 0
}

create_ufw_profile() {
  local app_profile_path="/etc/ufw/applications.d/docker-swarm"
  local profile_content
  profile_content="[Docker Swarm]\ntitle=Docker Swarm Communication Ports\ndescription=Ports needed for Docker Swarm to function across nodes (TCP 2377, TCP/UDP 7946, UDP 4789)\nports=2377/tcp|7946/tcp|7946/udp|4789/udp"

  local cmd
  cmd="echo -e \"${profile_content}\" | tee \"${app_profile_path}\" > /dev/null"

  executeCommand \
    "Creating UFW profile" \
    "${cmd}" \
    "Profile created at ${app_profile_path}" \
    "Failed to create profile"
}

main() {
  log_info "Setting up UFW application profile for Docker Swarm..."

  if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run with sudo or as root."
    exit 1
  fi

  if ! create_ufw_profile; then
    exit 1
  fi

  executeCommand "Updating UFW app profiles" "ufw app update 'Docker Swarm' > /dev/null" "Profiles updated" "Failed to update profiles"
  executeCommand "Reloading firewall rules" "ufw reload > /dev/null" "Firewall reloaded" "Failed to reload firewall"

  log_success "UFW Docker Swarm profile setup complete!"
  echo ""
  log_info "To allow traffic from other nodes, run:"
  log_info "sudo ufw allow from <IP_OF_OTHER_NODE> to any app 'Docker Swarm'"
}

main "$@"