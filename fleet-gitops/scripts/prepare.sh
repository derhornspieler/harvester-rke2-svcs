#!/usr/bin/env bash
set -euo pipefail

# prepare.sh — Interactive setup for Fleet GitOps deployment environment
#
# Bootstraps .env from .env.example, prompts for credentials, and manages
# Rancher API token lifecycle (login → cleanup old tokens → create new one).
#
# Usage:
#   ./prepare.sh              # Interactive setup (first-time or refresh)
#   ./prepare.sh --token-only # Skip .env prompts, just refresh Rancher token
#
# Prerequisites:
#   - curl, sed, python3
#   - Rancher admin credentials (prompted interactively, not stored)

###############################################################################
# Setup
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_DIR="$(dirname "${SCRIPT_DIR}")"
SVCS_DIR="$(dirname "${FLEET_DIR}")"
ENV_FILE="${FLEET_DIR}/.env"
ENV_EXAMPLE="${FLEET_DIR}/.env.example"

TOKEN_ONLY=false
if [[ "${1:-}" == "--token-only" ]]; then
  TOKEN_ONLY=true
fi

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# --- Logging ---
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
die()       { log_error "$*"; exit 1; }

# --- Prerequisites ---
check_prereqs() {
  local missing=()
  command -v curl    &>/dev/null || missing+=("curl")
  command -v sed     &>/dev/null || missing+=("sed")
  command -v python3 &>/dev/null || missing+=("python3")

  if (( ${#missing[@]} > 0 )); then
    die "Missing required tools: ${missing[*]}"
  fi
}

###############################################################################
# Helpers
###############################################################################

# Mask a secret value for display: first 15 chars + ... + last 4 chars
mask_secret() {
  local val="$1"
  local len=${#val}
  if (( len <= 19 )); then
    echo "${val}"
  else
    echo "${val:0:15}...${val: -4}"
  fi
}

# Prompt for a variable. Shows current value, accepts Enter to keep.
# Usage: prompt_var VARNAME "Prompt text" [secret]
prompt_var() {
  local varname="$1"
  local prompt_text="$2"
  local is_secret="${3:-}"
  local current_val="${!varname:-}"
  local display_val

  if [[ -n "${current_val}" ]]; then
    if [[ "${is_secret}" == "secret" ]]; then
      display_val="$(mask_secret "${current_val}")"
    else
      display_val="${current_val}"
    fi
    echo -en "${BOLD}${prompt_text}${NC} [${display_val}]: "
  else
    echo -en "${BOLD}${prompt_text}${NC}: "
  fi

  local user_input
  read -r user_input

  if [[ -n "${user_input}" ]]; then
    eval "${varname}=\"\${user_input}\""
  fi

  # Validate non-empty
  if [[ -z "${!varname:-}" ]]; then
    die "${varname} cannot be empty"
  fi
}

# Update a variable in .env — handles both existing and missing keys
update_env_var() {
  local varname="$1"
  local value="${!varname}"

  # Escape special characters for sed
  local escaped_value
  escaped_value=$(printf '%s' "${value}" | sed 's/[&/\]/\\&/g')

  if grep -q "^${varname}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${varname}=.*|${varname}=${escaped_value}|" "${ENV_FILE}"
  else
    echo "${varname}=${escaped_value}" >> "${ENV_FILE}"
  fi
}

###############################################################################
# Rancher Token Management
###############################################################################

# Authenticate with Rancher and get a session token
rancher_login() {
  local url="$1"
  local username="$2"
  local password="$3"

  local response
  response=$(curl -sk \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${username}\",\"password\":\"${password}\"}" \
    "${url}/v3-public/localProviders/local?action=login" 2>/dev/null) || true

  local token
  token=$(echo "${response}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('token', ''))
except:
    print('')
" 2>/dev/null)

  if [[ -z "${token}" ]]; then
    local error_msg
    error_msg=$(echo "${response}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('message', 'Unknown error'))
except:
    print('Could not parse response')
" 2>/dev/null)
    die "Rancher login failed: ${error_msg}"
  fi

  echo "${token}"
}

# Clean up old fleet-gitops-deploy tokens
rancher_cleanup_tokens() {
  local url="$1"
  local session_token="$2"
  local description_prefix="fleet-gitops-deploy"

  log_info "Checking for existing ${description_prefix} tokens..."

  local tokens_json
  tokens_json=$(curl -sk \
    -H "Authorization: Bearer ${session_token}" \
    "${url}/v3/tokens" 2>/dev/null)

  # Find tokens with our description prefix
  local token_ids
  token_ids=$(echo "${tokens_json}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for t in d.get('data', []):
        desc = t.get('description', '')
        if desc.startswith('${description_prefix}'):
            print(t['id'])
except:
    pass
" 2>/dev/null)

  local count=0
  while IFS= read -r tid; do
    [[ -n "${tid}" ]] || continue
    local code
    code=$(curl -sk -o /dev/null -w "%{http_code}" \
      -X DELETE \
      -H "Authorization: Bearer ${session_token}" \
      "${url}/v3/tokens/${tid}" 2>/dev/null)
    if [[ "${code}" == "204" || "${code}" == "200" ]]; then
      ((count++))
    else
      log_warn "Failed to delete token ${tid} (HTTP ${code})"
    fi
  done <<< "${token_ids}"

  if (( count > 0 )); then
    log_ok "Deleted ${count} old ${description_prefix} token(s)"
  else
    log_info "No old ${description_prefix} tokens found"
  fi
}

# Create a new no-expiry global API token
rancher_create_token() {
  local url="$1"
  local session_token="$2"
  local description="fleet-gitops-deploy ($(date +%Y-%m-%d))"

  log_info "Creating new API token: ${description}"

  local response
  response=$(curl -sk \
    -X POST \
    -H "Authorization: Bearer ${session_token}" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"token\",\"description\":\"${description}\",\"ttl\":0}" \
    "${url}/v3/tokens" 2>/dev/null)

  local new_token
  new_token=$(echo "${response}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('token', ''))
except:
    print('')
" 2>/dev/null)

  if [[ -z "${new_token}" ]]; then
    local error_msg
    error_msg=$(echo "${response}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('message', 'Unknown error'))
except:
    print('Could not parse response')
" 2>/dev/null)
    die "Failed to create API token: ${error_msg}"
  fi

  echo "${new_token}"
}

###############################################################################
# Validation
###############################################################################

validate_rancher() {
  local url="$1"
  local token="$2"

  local code
  code=$(curl -sk -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${token}" \
    "${url}/v3" 2>/dev/null)

  if [[ "${code}" == "200" ]]; then
    log_ok "Rancher API access verified"
    return 0
  else
    log_error "Rancher API returned HTTP ${code}"
    return 1
  fi
}

validate_harbor() {
  local host="$1"
  local user="$2"
  local pass="$3"

  local code
  code=$(curl -sk -o /dev/null -w "%{http_code}" \
    -u "${user}:${pass}" \
    "https://${host}/api/v2.0/health" 2>/dev/null)

  if [[ "${code}" == "200" ]]; then
    log_ok "Harbor access verified (${host})"
    return 0
  else
    log_warn "Harbor returned HTTP ${code} — check HARBOR_HOST/HARBOR_USER/HARBOR_PASS"
    return 1
  fi
}

validate_root_ca() {
  local root_ca_pem="${SVCS_DIR}/services/pki/roots/root-ca.pem"
  local root_ca_key="${SVCS_DIR}/services/pki/roots/root-ca-key.pem"

  if [[ -f "${root_ca_pem}" && -f "${root_ca_key}" ]]; then
    log_ok "Root CA files found"
    return 0
  else
    log_warn "Root CA files missing (expected at services/pki/roots/root-ca.{pem,key})"
    log_warn "Phase 2 (Seed Root CA) will fail without these — generate them first"
    return 1
  fi
}

###############################################################################
# Main
###############################################################################

main() {
  echo ""
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo -e "${BOLD}${BLUE}  Fleet GitOps — Environment Preparation${NC}"
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo ""

  check_prereqs

  # --- Bootstrap .env ---
  if [[ ! -f "${ENV_FILE}" ]]; then
    if [[ -f "${ENV_EXAMPLE}" ]]; then
      log_info "No .env found — copying from .env.example"
      cp "${ENV_EXAMPLE}" "${ENV_FILE}"
      log_ok "Created ${ENV_FILE}"
    else
      die ".env.example not found at ${ENV_EXAMPLE}"
    fi
  else
    log_ok "Using existing .env"
  fi

  # Source current values
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a

  # --- Interactive prompts ---
  if [[ "${TOKEN_ONLY}" != true ]]; then
    echo ""
    echo -e "${BOLD}Configuration${NC} (press Enter to keep current value)"
    echo -e "------------------------------------------------------------"
    echo ""

    prompt_var RANCHER_URL    "Rancher URL"
    prompt_var HARBOR_HOST    "Harbor hostname"
    prompt_var HARBOR_USER    "Harbor username"
    prompt_var HARBOR_PASS    "Harbor password" secret
    prompt_var DOMAIN         "Base domain"
    prompt_var FLEET_TARGET_CLUSTER "Fleet target cluster"
    prompt_var TRAEFIK_LB_IP  "Traefik LB IP"

    # Write non-token values to .env
    update_env_var RANCHER_URL
    update_env_var HARBOR_HOST
    update_env_var HARBOR_USER
    update_env_var HARBOR_PASS
    update_env_var DOMAIN
    update_env_var FLEET_TARGET_CLUSTER
    update_env_var TRAEFIK_LB_IP
  fi

  # --- Rancher Token Management ---
  echo ""
  echo -e "${BOLD}Rancher API Token${NC}"
  echo -e "------------------------------------------------------------"

  # Check if current token is still valid
  local current_valid=false
  if [[ -n "${RANCHER_TOKEN:-}" ]]; then
    if validate_rancher "${RANCHER_URL}" "${RANCHER_TOKEN}" 2>/dev/null; then
      current_valid=true
    else
      log_warn "Current Rancher token is invalid or expired"
    fi
  else
    log_info "No Rancher token configured"
  fi

  if [[ "${current_valid}" == true ]]; then
    echo -en "${BOLD}Current token is valid. Refresh it anyway?${NC} [y/N]: "
    local refresh_choice
    read -r refresh_choice
    if [[ "${refresh_choice}" != "y" && "${refresh_choice}" != "Y" ]]; then
      log_ok "Keeping current token"
      # Skip to validation
      echo ""
      echo -e "${BOLD}Validation${NC}"
      echo -e "------------------------------------------------------------"
      validate_rancher "${RANCHER_URL}" "${RANCHER_TOKEN}" || true
      validate_harbor "${HARBOR_HOST}" "${HARBOR_USER}" "${HARBOR_PASS}" || true
      validate_root_ca || true
      print_summary
      return 0
    fi
  fi

  # Prompt for Rancher credentials (not stored)
  echo ""
  log_info "Authenticating with Rancher to create API token..."
  log_info "Credentials are used once and not stored."
  echo ""
  echo -en "${BOLD}Rancher admin username${NC}: "
  local rancher_user
  read -r rancher_user
  [[ -n "${rancher_user}" ]] || die "Username cannot be empty"

  echo -en "${BOLD}Rancher admin password${NC}: "
  local rancher_pass
  read -rs rancher_pass
  echo ""
  [[ -n "${rancher_pass}" ]] || die "Password cannot be empty"

  # Login
  log_info "Logging in to ${RANCHER_URL}..."
  local session_token
  session_token=$(rancher_login "${RANCHER_URL}" "${rancher_user}" "${rancher_pass}")
  log_ok "Authenticated as ${rancher_user}"

  # Cleanup old tokens
  rancher_cleanup_tokens "${RANCHER_URL}" "${session_token}"

  # Create new token
  RANCHER_TOKEN=$(rancher_create_token "${RANCHER_URL}" "${session_token}")
  log_ok "New API token created: $(mask_secret "${RANCHER_TOKEN}")"

  # Write to .env
  update_env_var RANCHER_TOKEN
  log_ok "Token saved to .env"

  # --- Validation ---
  echo ""
  echo -e "${BOLD}Validation${NC}"
  echo -e "------------------------------------------------------------"

  validate_rancher "${RANCHER_URL}" "${RANCHER_TOKEN}" || true
  validate_harbor "${HARBOR_HOST}" "${HARBOR_USER}" "${HARBOR_PASS}" || true
  validate_root_ca || true

  print_summary
}

print_summary() {
  echo ""
  echo -e "${BOLD}${GREEN}============================================================${NC}"
  echo -e "${BOLD}${GREEN}  Environment Ready${NC}"
  echo -e "${BOLD}${GREEN}============================================================${NC}"
  echo ""
  echo -e "  Rancher:  ${RANCHER_URL}"
  echo -e "  Harbor:   ${HARBOR_HOST}"
  echo -e "  Domain:   ${DOMAIN}"
  echo -e "  Cluster:  ${FLEET_TARGET_CLUSTER}"
  echo -e "  Token:    $(mask_secret "${RANCHER_TOKEN}")"
  echo ""
  echo -e "  Next steps:"
  echo -e "    ${BOLD}./scripts/deploy.sh${NC}              # Full deployment"
  echo -e "    ${BOLD}./scripts/deploy.sh --skip-push${NC}  # Skip chart push"
  echo -e "    ${BOLD}./scripts/prepare.sh --token-only${NC} # Refresh token only"
  echo ""
}

main "$@"
