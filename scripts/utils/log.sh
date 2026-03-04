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
