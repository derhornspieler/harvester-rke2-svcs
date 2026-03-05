#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source log utility only — no Helm/wait needed for API-only setup
source "${SCRIPT_DIR}/utils/log.sh"

# Load environment
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
fi

# Domain and Keycloak settings
DOMAIN="${DOMAIN:?DOMAIN must be set}"
KC_REALM="${KC_REALM:-platform}"
KC_URL="https://keycloak.${DOMAIN}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:?KC_ADMIN_PASSWORD must be set in .env}"
BREAKGLASS_PASSWORD="${BREAKGLASS_PASSWORD:?BREAKGLASS_PASSWORD must be set in .env}"

# CLI Parsing
PHASE_FROM=1
PHASE_TO=6

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Configure Keycloak via Admin REST API (post-deploy setup).
Requires Keycloak to be running and reachable at ${KC_URL}.

Options:
  --phase N       Run only phase N
  --from N        Start from phase N (default: 1)
  --to N          Stop after phase N (default: 6)
  -h, --help      Show this help

Phases:
  1  Create realm              Create the "${KC_REALM}" realm
  2  Create breakglass user    Create admin-breakglass user with password
  3  Create OIDC clients       grafana, prometheus-oidc, alertmanager-oidc, hubble-oidc
  4  Create groups             platform-admins group, assign breakglass user
  5  Authentication flow       Configure prompt=login custom browser flow
  6  Validation                Print summary of created resources
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)     PHASE_FROM="$2"; PHASE_TO="$2"; shift 2 ;;
    --from)      PHASE_FROM="$2"; shift 2 ;;
    --to)        PHASE_TO="$2"; shift 2 ;;
    -h|--help)   usage ;;
    *)           die "Unknown option: $1" ;;
  esac
done

###############################################################################
# Helper functions
###############################################################################

kc_get_token() {
  local token
  token=$(curl -sf -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" \
    -d "username=${KC_ADMIN_USER}" \
    -d "password=${KC_ADMIN_PASSWORD}" | jq -r '.access_token')
  if [[ -z "$token" || "$token" == "null" ]]; then
    die "Failed to obtain Keycloak admin token. Is Keycloak running at ${KC_URL}?"
  fi
  echo "$token"
}

kc_api() {
  local method="$1" path="$2"
  shift 2
  local token
  token=$(kc_get_token)
  curl -sf -X "$method" "${KC_URL}/admin/realms/${path}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    "$@"
}

# Idempotent create — returns 0 on success or 409 (already exists)
kc_api_create() {
  local method="$1" path="$2"
  shift 2
  local token http_code
  token=$(kc_get_token)
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X "$method" "${KC_URL}/admin/realms/${path}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    "$@")
  case "$http_code" in
    200|201|204) return 0 ;;
    409)         log_info "Resource already exists (409 conflict), skipping"; return 0 ;;
    *)           die "Keycloak API returned HTTP ${http_code} for ${method} ${path}" ;;
  esac
}

###############################################################################
# Phase 1: Create realm
###############################################################################
if [[ $PHASE_FROM -le 1 && $PHASE_TO -ge 1 ]]; then
  start_phase "Phase 1: Create Realm"
  log_info "Creating realm '${KC_REALM}'..."
  kc_api_create POST "" -d '{
    "realm": "'"${KC_REALM}"'",
    "enabled": true,
    "registrationAllowed": false,
    "loginWithEmailAllowed": true,
    "duplicateEmailsAllowed": false,
    "resetPasswordAllowed": true,
    "editUsernameAllowed": false,
    "bruteForceProtected": true,
    "permanentLockout": false,
    "maxFailureWaitSeconds": 900,
    "minimumQuickLoginWaitSeconds": 60,
    "waitIncrementSeconds": 60,
    "quickLoginCheckMilliSeconds": 1000,
    "maxDeltaTimeSeconds": 43200,
    "failureFactor": 5
  }'
  log_ok "Realm '${KC_REALM}' created"
  end_phase "Phase 1: Create Realm"
fi

###############################################################################
# Phase 2: Create admin-breakglass user
###############################################################################
if [[ $PHASE_FROM -le 2 && $PHASE_TO -ge 2 ]]; then
  start_phase "Phase 2: Create Breakglass User"
  log_info "Creating user 'admin-breakglass'..."
  # Use jq to safely construct JSON — prevents injection if password contains " or \
  _user_payload=$(jq -n \
    --arg pass "$BREAKGLASS_PASSWORD" \
    '{
      username: "admin-breakglass",
      enabled: true,
      emailVerified: true,
      credentials: [{type: "password", value: $pass, temporary: false}]
    }')
  kc_api_create POST "${KC_REALM}/users" -d "$_user_payload"

  # Get user ID for later group assignment
  BREAKGLASS_ID=$(kc_api GET "${KC_REALM}/users?username=admin-breakglass" | jq -r '.[0].id')
  if [[ -z "$BREAKGLASS_ID" || "$BREAKGLASS_ID" == "null" ]]; then
    die "Failed to retrieve admin-breakglass user ID"
  fi
  log_ok "User admin-breakglass created (ID: ${BREAKGLASS_ID})"
  end_phase "Phase 2: Create Breakglass User"
fi

###############################################################################
# Phase 3: Create OIDC clients
###############################################################################
if [[ $PHASE_FROM -le 3 && $PHASE_TO -ge 3 ]]; then
  start_phase "Phase 3: Create OIDC Clients"

  # Define redirect URIs per client
  declare -A CLIENT_REDIRECTS=(
    ["grafana"]="https://grafana.${DOMAIN}/login/generic_oauth"
    ["prometheus-oidc"]="https://prometheus.${DOMAIN}/oauth2/callback"
    ["alertmanager-oidc"]="https://alertmanager.${DOMAIN}/oauth2/callback"
    ["hubble-oidc"]="https://hubble.${DOMAIN}/oauth2/callback"
  )

  for client_id in grafana prometheus-oidc alertmanager-oidc hubble-oidc; do
    redirect_uri="${CLIENT_REDIRECTS[$client_id]}"
    log_info "Creating OIDC client '${client_id}'..."
    kc_api_create POST "${KC_REALM}/clients" -d '{
      "clientId": "'"${client_id}"'",
      "name": "'"${client_id}"'",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "clientAuthenticatorType": "client-secret",
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": false,
      "serviceAccountsEnabled": false,
      "redirectUris": ["'"${redirect_uri}"'"],
      "webOrigins": ["+"],
      "attributes": {
        "pkce.code.challenge.method": "S256",
        "login_theme": "",
        "post.logout.redirect.uris": "+"
      },
      "defaultClientScopes": ["openid", "profile", "email", "roles"],
      "optionalClientScopes": ["groups"]
    }'
    log_ok "OIDC client '${client_id}' created"
  done

  end_phase "Phase 3: Create OIDC Clients"
fi

###############################################################################
# Phase 4: Create groups and assign breakglass user
###############################################################################
if [[ $PHASE_FROM -le 4 && $PHASE_TO -ge 4 ]]; then
  start_phase "Phase 4: Create Groups + Assign Breakglass User"

  log_info "Creating group 'platform-admins'..."
  kc_api_create POST "${KC_REALM}/groups" -d '{"name": "platform-admins"}'

  GROUP_ID=$(kc_api GET "${KC_REALM}/groups?search=platform-admins" | jq -r '.[0].id')
  if [[ -z "$GROUP_ID" || "$GROUP_ID" == "null" ]]; then
    die "Failed to retrieve platform-admins group ID"
  fi
  log_ok "Group platform-admins created (ID: ${GROUP_ID})"

  # Retrieve breakglass user ID (in case phase 2 was run separately)
  BREAKGLASS_ID=$(kc_api GET "${KC_REALM}/users?username=admin-breakglass" | jq -r '.[0].id')
  if [[ -z "$BREAKGLASS_ID" || "$BREAKGLASS_ID" == "null" ]]; then
    die "admin-breakglass user not found. Run phase 2 first."
  fi

  log_info "Assigning admin-breakglass to platform-admins..."
  kc_api_create PUT "${KC_REALM}/users/${BREAKGLASS_ID}/groups/${GROUP_ID}"
  log_ok "admin-breakglass assigned to platform-admins"

  # Create groups mapper for the realm so groups appear in tokens
  log_info "Creating 'groups' client scope with groups mapper..."
  kc_api_create POST "${KC_REALM}/client-scopes" -d '{
    "name": "groups",
    "description": "Map user groups to token claims",
    "protocol": "openid-connect",
    "attributes": {
      "include.in.token.scope": "true",
      "display.on.consent.screen": "false"
    },
    "protocolMappers": [
      {
        "name": "groups",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-group-membership-mapper",
        "consentRequired": false,
        "config": {
          "full.path": "false",
          "introspection.token.claim": "true",
          "userinfo.token.claim": "true",
          "id.token.claim": "true",
          "access.token.claim": "true",
          "claim.name": "groups"
        }
      }
    ]
  }'
  log_ok "Groups client scope created with membership mapper"

  end_phase "Phase 4: Create Groups + Assign Breakglass User"
fi

###############################################################################
# Phase 5: Configure prompt=login authentication flow
###############################################################################
if [[ $PHASE_FROM -le 5 && $PHASE_TO -ge 5 ]]; then
  start_phase "Phase 5: Configure Authentication Flow"

  # Copy the built-in browser flow to a custom flow
  log_info "Copying browser flow to 'browser-prompt-login'..."
  BROWSER_FLOW=$(kc_api GET "${KC_REALM}/authentication/flows" \
    | jq -r '.[] | select(.alias == "browser") | .id')
  if [[ -z "$BROWSER_FLOW" || "$BROWSER_FLOW" == "null" ]]; then
    die "Could not find built-in browser flow"
  fi

  kc_api_create POST "${KC_REALM}/authentication/flows/${BROWSER_FLOW}/copy" \
    -d '{"newName": "browser-prompt-login"}'

  # Set the custom flow as the realm browser flow
  log_info "Setting browser-prompt-login as realm browser flow..."
  kc_api PUT "${KC_REALM}" -d '{
    "browserFlow": "browser-prompt-login"
  }' || log_warn "Could not set browser flow (may already be set)"

  log_ok "Authentication flow configured with prompt=login"
  end_phase "Phase 5: Configure Authentication Flow"
fi

###############################################################################
# Phase 6: Validation
###############################################################################
if [[ $PHASE_FROM -le 6 && $PHASE_TO -ge 6 ]]; then
  start_phase "Phase 6: Validation"
  log_ok "Keycloak setup complete"
  log_info "Realm: ${KC_REALM}"
  log_info "Admin user: admin-breakglass"
  log_info "OIDC clients: grafana, prometheus-oidc, alertmanager-oidc, hubble-oidc"
  log_info "Groups: platform-admins"
  log_info "Auth flow: browser-prompt-login (forces re-authentication)"
  log_info ""
  log_info "Next steps:"
  log_info "  1. Store OIDC client secrets in Vault (kv/oidc/<client-id>/client-secret)"
  log_info "  2. Run deploy-keycloak.sh --phase 7 to deploy OAuth2-proxy instances"
  log_info "  3. Configure Grafana OIDC in kube-prometheus-stack values"
  end_phase "Phase 6: Validation"
fi
