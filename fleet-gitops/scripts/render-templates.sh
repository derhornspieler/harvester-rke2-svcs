#!/usr/bin/env bash
set -euo pipefail

# render-templates.sh — Render fleet-gitops templates with environment variables
#
# Reads .env, computes derived variables, then runs envsubst on all YAML
# files in the bundle directories. Output goes to rendered/ which mirrors
# the source structure.
#
# Usage:
#   ./render-templates.sh              # Render all bundles
#   ./render-templates.sh --check      # Dry run: show what would change
#   ./render-templates.sh --diff       # Show diff between source and rendered

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_DIR="$(dirname "${SCRIPT_DIR}")"
RENDERED_DIR="${FLEET_DIR}/rendered"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
die()       { log_error "$*"; exit 1; }

# --- Load environment ---
env_file="${FLEET_DIR}/.env"
[[ -f "${env_file}" ]] || die ".env not found at ${env_file}. Copy .env.example to .env and fill in values."

set -a
# shellcheck source=/dev/null
source "${env_file}"
set +a

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/env-defaults.sh"

# --- Argument parsing ---
CHECK_MODE=false
DIFF_MODE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_MODE=true; shift ;;
    --diff)  DIFF_MODE=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--check] [--diff]"
      echo "  --check  Show what files would be rendered (dry run)"
      echo "  --diff   Show diff between source templates and rendered output"
      exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# --- Collect template files ---
# All YAML files in bundle directories (excluding rendered/, scripts/, .git/)
mapfile -t TEMPLATE_FILES < <(find "${FLEET_DIR}" \
  -path "${RENDERED_DIR}" -prune -o \
  -path "${FLEET_DIR}/scripts" -prune -o \
  -path "${FLEET_DIR}/.git" -prune -o \
  \( -name "*.yaml" -o -name "*.yml" \) -print | sort)

if [[ "${CHECK_MODE}" == true ]]; then
  log_info "Files that would be rendered (${#TEMPLATE_FILES[@]} total):"
  printf '%s\n' "${TEMPLATE_FILES[@]}" | sed "s|${FLEET_DIR}/||"
  exit 0
fi

# --- Render ---
rm -rf "${RENDERED_DIR}"
rendered=0
changed=0
unchanged=0

for src in "${TEMPLATE_FILES[@]}"; do
  rel="${src#"${FLEET_DIR}/"}"
  dest="${RENDERED_DIR}/${rel}"
  dest_dir="$(dirname "${dest}")"
  mkdir -p "${dest_dir}"

  # Run envsubst with explicit variable list (preserves $VAR in embedded shell)
  envsubst "${ENVSUBST_VARS}" < "${src}" > "${dest}"
  rendered=$((rendered + 1))

  if [[ "${DIFF_MODE}" == true ]]; then
    if ! diff -q "${src}" "${dest}" > /dev/null 2>&1; then
      echo -e "\n${YELLOW}--- ${rel} ---${NC}"
      diff --color=always -u "${src}" "${dest}" || true
      changed=$((changed + 1))
    else
      unchanged=$((unchanged + 1))
    fi
  fi
done

if [[ "${DIFF_MODE}" == true ]]; then
  log_info "${changed} files changed, ${unchanged} unchanged out of ${rendered} total"
else
  log_ok "Rendered ${rendered} files to ${RENDERED_DIR}/"
fi
