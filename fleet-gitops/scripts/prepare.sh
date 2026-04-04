#!/usr/bin/env bash
set -euo pipefail
umask 077  # All created files are owner-only (secrets in .env)

# prepare.sh — Interactive setup for Fleet GitOps deployment environment
#
# Bootstraps .env from .env.example, prompts for credentials, and manages
# Rancher API token lifecycle (login → cleanup old tokens → create new one).
#
# Usage:
#   ./prepare.sh                                  # Interactive setup using .env
#   ./prepare.sh --env .env.rke2-test             # Setup for a specific environment
#   ./prepare.sh --token-only                     # Refresh Rancher token in .env
#   ./prepare.sh --env .env.rke2-test --token-only # Refresh token in specific env file
#
# Prerequisites:
#   - curl, python3, jq
#   - Rancher admin credentials (prompted interactively, not stored)

###############################################################################
# Setup
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_DIR="$(dirname "${SCRIPT_DIR}")"
SVCS_DIR="$(dirname "${FLEET_DIR}")"

# Parse --env <file> from args (prepare.sh skips sourcing — it bootstraps the file)
_env_prep_file="${FLEET_DIR}/.env"
_env_prep_args=()
_env_prep_skip=false
for _env_prep_arg in "$@"; do
  if [[ "${_env_prep_skip}" == true ]]; then
    _env_prep_file="${_env_prep_arg}"
    _env_prep_skip=false
    continue
  fi
  if [[ "${_env_prep_arg}" == "--env" ]]; then
    _env_prep_skip=true
    continue
  fi
  _env_prep_args+=("${_env_prep_arg}")
done
unset _env_prep_skip _env_prep_arg
# Resolve relative paths against FLEET_DIR
if [[ ! "${_env_prep_file}" = /* ]]; then
  _env_prep_file="${FLEET_DIR}/${_env_prep_file}"
fi
ENV_FILE="${_env_prep_file}"
unset _env_prep_file
set -- "${_env_prep_args[@]+"${_env_prep_args[@]}"}"
unset _env_prep_args
ENV_EXAMPLE="${FLEET_DIR}/.env.example"

TOKEN_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token-only) TOKEN_ONLY=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--env <file>] [--token-only]"
      echo ""
      echo "  --env <file>   Use a specific environment file (default: .env)"
      echo "  --token-only   Skip .env prompts, just refresh Rancher token"
      echo ""
      echo "Examples:"
      echo "  $0                                         # Interactive setup using .env"
      echo "  $0 --env .env.rke2-test                    # Setup for a specific environment"
      echo "  $0 --token-only                            # Refresh Rancher token in .env"
      echo "  $0 --env .env.rke2-test --token-only       # Refresh token in specific env file"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# --- Logging (all to stderr so function return values stay clean on stdout) ---
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()       { log_error "$*"; exit 1; }

# --- Prerequisites ---
check_prereqs() {
  local missing=()
  command -v curl    &>/dev/null || missing+=("curl")
  command -v python3 &>/dev/null || missing+=("python3")
  command -v jq      &>/dev/null || missing+=("jq")

  if (( ${#missing[@]} > 0 )); then
    die "Missing required tools: ${missing[*]}"
  fi
}

###############################################################################
# Helpers
###############################################################################

# Mask a secret value for display — show minimal chars to confirm identity
mask_secret() {
  local val="$1"
  local len=${#val}
  if (( len <= 8 )); then
    echo "****"
  else
    echo "${val:0:4}...${val: -2}"
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

  # SECURITY: use printf -v instead of eval to prevent command injection
  if [[ -n "${user_input}" ]]; then
    printf -v "${varname}" '%s' "${user_input}"
  fi

  # Validate non-empty
  if [[ -z "${!varname:-}" ]]; then
    die "${varname} cannot be empty"
  fi
}

# Update a variable in .env — handles both existing and missing keys
# Uses python3 for safe replacement with single-quoted values to prevent
# shell expansion when .env is sourced
update_env_var() {
  local varname="$1"
  local value="${!varname}"

  python3 -c "
import sys, re, os
varname, value, path = sys.argv[1], sys.argv[2], sys.argv[3]
# Single-quote the value to prevent shell expansion when sourced
# Escape any embedded single quotes: ' → '\''
safe_value = \"'\" + value.replace(\"'\", \"'\\\\''\" ) + \"'\"
line = varname + '=' + safe_value
with open(path, 'r') as f:
    content = f.read()
pattern = r'^' + re.escape(varname) + r'=.*$'
if re.search(pattern, content, flags=re.MULTILINE):
    content = re.sub(pattern, line, content, flags=re.MULTILINE)
else:
    content = content.rstrip('\n') + '\n' + line + '\n'
with open(path, 'w') as f:
    f.write(content)
" "${varname}" "${value}" "${ENV_FILE}"
}

###############################################################################
# Rancher Token Management
###############################################################################

# Authenticate with Rancher and get a session token
rancher_login() {
  local url="$1"
  local username="$2"
  local password="$3"

  # SECURITY: construct JSON via jq to prevent injection from credentials
  # containing quotes or special characters. Pipe via stdin to avoid
  # exposing the password in /proc/cmdline.
  local payload
  payload=$(jq -n --arg u "${username}" --arg p "${password}" \
    '{"username": $u, "password": $p}')

  local response
  response=$(printf '%s' "${payload}" | curl -sk \
    -X POST \
    -H "Content-Type: application/json" \
    -d @- \
    "${url}/v3-public/localProviders/local?action=login" 2>/dev/null) || true

  local token
  token=$(printf '%s' "${response}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('token', ''))
except (json.JSONDecodeError, KeyError, TypeError):
    print('')
" 2>/dev/null)

  if [[ -z "${token}" ]]; then
    die "Rancher login failed (check credentials and URL)"
  fi

  echo "${token}"
}

# Clean up old fleet-gitops-deploy tokens
rancher_cleanup_tokens() {
  local url="$1"
  local session_token="$2"

  log_info "Checking for existing fleet-gitops-deploy tokens..."

  # Stream the response through python3 to avoid loading the full /v3/tokens
  # payload into a shell variable (can be tens of MB on busy Rancher instances).
  # SECURITY: pass the prefix as a CLI arg to python3, not via shell interpolation
  local token_ids
  token_ids=$(curl -sk \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "${session_token}") \
    "${url}/v3/tokens?limit=200" 2>/dev/null | \
    python3 -c "
import sys, json
prefix = sys.argv[1]
try:
    d = json.load(sys.stdin)
    for t in d.get('data', []):
        desc = t.get('description', '') or ''
        if desc.startswith(prefix):
            print(t['id'])
except (json.JSONDecodeError, KeyError, TypeError):
    pass
" "fleet-gitops-deploy" 2>/dev/null) || true

  local count=0
  while IFS= read -r tid; do
    [[ -n "${tid}" ]] || continue
    local code
    code=$(curl -sk -o /dev/null -w "%{http_code}" \
      -X DELETE \
      --config <(printf 'header = "Authorization: Bearer %s"\n' "${session_token}") \
      "${url}/v3/tokens/${tid}" 2>/dev/null)
    if [[ "${code}" == "204" || "${code}" == "200" ]]; then
      ((count++))
    else
      log_warn "Failed to delete token ${tid} (HTTP ${code})"
    fi
  done <<< "${token_ids}"

  if (( count > 0 )); then
    log_ok "Deleted ${count} old fleet-gitops-deploy token(s)"
  else
    log_info "No old fleet-gitops-deploy tokens found"
  fi
}

# Create a new no-expiry global API token
rancher_create_token() {
  local url="$1"
  local session_token="$2"
  local description="fleet-gitops-deploy ($(date +%Y-%m-%d))"

  log_info "Creating new API token: ${description}"

  # SECURITY: construct JSON via jq to prevent injection via description
  local payload
  payload=$(jq -n --arg desc "${description}" \
    '{"type": "token", "description": $desc, "ttl": 0}')

  local response
  response=$(printf '%s' "${payload}" | curl -sk \
    -X POST \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "${session_token}") \
    -H "Content-Type: application/json" \
    -d @- \
    "${url}/v3/tokens" 2>/dev/null)

  local new_token
  new_token=$(printf '%s' "${response}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('token', ''))
except (json.JSONDecodeError, KeyError, TypeError):
    print('')
" 2>/dev/null)

  if [[ -z "${new_token}" ]]; then
    die "Failed to create API token (check Rancher permissions)"
  fi

  echo "${new_token}"
}

# Invalidate the session token after use
rancher_logout() {
  local url="$1"
  local session_token="$2"

  # Extract the token ID (everything before the colon)
  local session_id="${session_token%%:*}"
  curl -sk -o /dev/null \
    -X DELETE \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "${session_token}") \
    "${url}/v3/tokens/${session_id}" 2>/dev/null || true
  log_info "Session token invalidated"
}

###############################################################################
# Validation
###############################################################################

validate_rancher() {
  local url="$1"
  local token="$2"

  local code
  code=$(curl -sk -o /dev/null -w "%{http_code}" \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "${token}") \
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

  # SECURITY: pass credentials via --config to avoid exposure in /proc/cmdline
  local code
  code=$(curl -sk -o /dev/null -w "%{http_code}" \
    --config <(printf 'user = "%s:%s"\n' "${user}" "${pass}") \
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

  if [[ -f "${root_ca_pem}" ]]; then
    log_ok "Root CA certificate found"
  else
    log_warn "Root CA certificate missing (expected at services/pki/roots/root-ca.pem)"
    log_warn "Phase 2 (Seed Root CA) will fail without it — generate it first"
    return 1
  fi

  if [[ -f "${root_ca_key}" ]]; then
    log_warn "Root CA private key found on disk — move to offline storage after bootstrap"
  fi

  return 0
}

###############################################################################
# Main
###############################################################################

main() {
  echo "" >&2
  echo -e "${BOLD}${BLUE}============================================================${NC}" >&2
  echo -e "${BOLD}${BLUE}  Fleet GitOps — Environment Preparation${NC}" >&2
  echo -e "${BOLD}${BLUE}============================================================${NC}" >&2
  echo "" >&2

  check_prereqs

  # --- Bootstrap .env ---
  if [[ ! -f "${ENV_FILE}" ]]; then
    if [[ -f "${ENV_EXAMPLE}" ]]; then
      log_info "No .env found — copying from .env.example"
      cp "${ENV_EXAMPLE}" "${ENV_FILE}"
      chmod 600 "${ENV_FILE}"
      log_ok "Created ${ENV_FILE} (mode 600)"
    else
      die ".env.example not found at ${ENV_EXAMPLE}"
    fi
  else
    # Ensure existing .env has restrictive permissions
    chmod 600 "${ENV_FILE}"
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

  # Invalidate the session token — no longer needed
  rancher_logout "${RANCHER_URL}" "${session_token}"

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
  echo "" >&2
  echo -e "${BOLD}${GREEN}============================================================${NC}" >&2
  echo -e "${BOLD}${GREEN}  Environment Ready${NC}" >&2
  echo -e "${BOLD}${GREEN}============================================================${NC}" >&2
  echo "" >&2
  echo -e "  Rancher:  ${RANCHER_URL}" >&2
  echo -e "  Harbor:   ${HARBOR_HOST}" >&2
  echo -e "  Domain:   ${DOMAIN}" >&2
  echo -e "  Cluster:  ${FLEET_TARGET_CLUSTER}" >&2
  echo -e "  Token:    $(mask_secret "${RANCHER_TOKEN}")" >&2
  echo "" >&2
  echo -e "  Next steps:" >&2
  echo -e "    ${BOLD}./scripts/deploy.sh${NC}              # Full deployment" >&2
  echo -e "    ${BOLD}./scripts/deploy.sh --skip-push${NC}  # Skip chart push" >&2
  echo -e "    ${BOLD}./scripts/prepare.sh --token-only${NC} # Refresh token only" >&2
  echo "" >&2
}

main "$@"
