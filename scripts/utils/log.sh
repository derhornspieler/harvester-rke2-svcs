#!/usr/bin/env bash
# log.sh — Colored logging and phase timing utilities
# Source this file; do not execute directly.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

PHASE_START_TIME=""

start_phase() {
  PHASE_START_TIME=$(date +%s)
  local phase_name="$1"
  echo ""
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo -e "${BOLD}${BLUE}  ${phase_name}${NC}"
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo ""
}

end_phase() {
  local phase_name="$1"
  if [[ -z "$PHASE_START_TIME" ]]; then
    log_warn "end_phase called without start_phase"
    return
  fi
  local elapsed=$(( $(date +%s) - PHASE_START_TIME ))
  local mins=$(( elapsed / 60 ))
  local secs=$(( elapsed % 60 ))
  echo ""
  echo -e "${GREEN}--- ${phase_name} completed in ${mins}m ${secs}s ---${NC}"
}

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

die() {
  log_error "$@"
  exit 1
}

# require_env — Validate that all listed env vars are set and non-empty.
# Usage: require_env VAR1 VAR2 VAR3 ...
# Fails with a complete list of ALL missing vars (not just the first one).
require_env() {
  local missing=()
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required environment variables (check scripts/.env):"
    for var in "${missing[@]}"; do
      echo "  - $var" >&2
    done
    exit 1
  fi
}
