#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source utility modules
source "${SCRIPT_DIR}/utils/log.sh"
source "${SCRIPT_DIR}/utils/vault.sh"

# Load environment
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
fi

# Domain and Keycloak settings
DOMAIN="${DOMAIN:?DOMAIN must be set}"
KC_REALM="${KC_REALM:-platform}"
KC_URL="${KC_URL:-https://keycloak.${DOMAIN}}"

# Vault init file (to read admin credentials)
VAULT_INIT_FILE="${VAULT_INIT_FILE:-${REPO_ROOT}/vault-init.json}"

# Read Keycloak admin credentials from Vault if not set in environment
if [[ -z "${KC_ADMIN_USER:-}" || -z "${KC_ADMIN_PASSWORD:-}" ]]; then
  if [[ -f "$VAULT_INIT_FILE" ]]; then
    _root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")
    KC_ADMIN_USER=$(kubectl exec -n vault vault-0 -- env \
      VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$_root_token" \
      vault kv get -field=KC_BOOTSTRAP_ADMIN_USERNAME kv/services/keycloak/admin-secret 2>/dev/null) || true
    KC_ADMIN_PASSWORD=$(kubectl exec -n vault vault-0 -- env \
      VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$_root_token" \
      vault kv get -field=KC_BOOTSTRAP_ADMIN_PASSWORD kv/services/keycloak/admin-secret 2>/dev/null) || true
  fi
fi

KC_ADMIN_USER="${KC_ADMIN_USER:?KC_ADMIN_USER could not be read from Vault or .env}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:?KC_ADMIN_PASSWORD could not be read from Vault or .env}"

# Platform admin user credentials (replaces legacy admin-breakglass)
PLATFORM_ADMIN_USER="${PLATFORM_ADMIN_USER:-CHANGEME_ADMIN_USER}"
PLATFORM_ADMIN_EMAIL="${PLATFORM_ADMIN_EMAIL:-${PLATFORM_ADMIN_USER}@${DOMAIN}}"
PLATFORM_ADMIN_PASSWORD="${PLATFORM_ADMIN_PASSWORD:-${KC_ADMIN_PASSWORD}}"

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
  2  Create platform admin     Create ${PLATFORM_ADMIN_USER} user with password
  3  Create OIDC clients       grafana, prometheus-oidc, alertmanager-oidc, hubble-oidc, argocd, harbor, gitlab
  4  Create groups             platform-admins group, assign platform admin user
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

# Pre-cache admin credentials from Vault (called once at script start)
# Uses admin-cli with password grant (works out-of-the-box, no client registration needed)
_kc_init_credentials() {
  [[ -f "$VAULT_INIT_FILE" ]] || die "Vault init file not found: ${VAULT_INIT_FILE}"
  _root_token="${_root_token:-$(jq -r '.root_token' "$VAULT_INIT_FILE")}"
  _KC_ADMIN_USER=$(kubectl exec -n vault vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$_root_token" \
    vault kv get -field=KC_BOOTSTRAP_ADMIN_USERNAME kv/services/keycloak/admin-secret 2>/dev/null) || true
  _KC_ADMIN_PASS=$(kubectl exec -n vault vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$_root_token" \
    vault kv get -field=KC_BOOTSTRAP_ADMIN_PASSWORD kv/services/keycloak/admin-secret 2>/dev/null) || true
  [[ -n "$_KC_ADMIN_USER" && -n "$_KC_ADMIN_PASS" ]] || \
    die "Could not read admin credentials from Vault"
  log_info "Using admin user: ${_KC_ADMIN_USER}"
}
_kc_init_credentials

# Token cache file — avoids subshell variable loss
_KC_TOKEN_FILE=$(mktemp /tmp/kc-token.XXXXXX)
_KC_TOKEN_TIME_FILE=$(mktemp /tmp/kc-token-time.XXXXXX)
echo "0" > "$_KC_TOKEN_TIME_FILE"
trap 'rm -f "$_KC_TOKEN_FILE" "$_KC_TOKEN_TIME_FILE"' EXIT

kc_get_token() {
  local now cached_time
  now=$(date +%s)
  cached_time=$(cat "$_KC_TOKEN_TIME_FILE" 2>/dev/null || echo "0")
  # Return cached token if fresh (less than 20s old — master realm token TTL is 300s)
  if [[ -s "$_KC_TOKEN_FILE" && $(( now - cached_time )) -lt 20 ]]; then
    cat "$_KC_TOKEN_FILE"
    return 0
  fi

  local token attempt
  for attempt in 1 2 3; do
    token=$(curl -sf --http1.1 --connect-timeout 15 --max-time 60 \
      -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
      -d "grant_type=password" \
      -d "client_id=admin-cli" \
      -d "username=${_KC_ADMIN_USER}" \
      --data-urlencode "password=${_KC_ADMIN_PASS}" 2>/dev/null | jq -r '.access_token' 2>/dev/null) || true
    if [[ -n "$token" && "$token" != "null" ]]; then
      echo "$token" > "$_KC_TOKEN_FILE"
      date +%s > "$_KC_TOKEN_TIME_FILE"
      echo "$token"
      return 0
    fi
    log_warn "Token attempt ${attempt} failed, retrying in 2s..." >&2
    sleep 2
  done
  log_error "Failed to obtain Keycloak admin token after 3 attempts" >&2
  return 1
}

kc_api() {
  local method="$1" path="$2"
  shift 2
  local token attempt
  for attempt in 1 2 3; do
    token=$(kc_get_token)
    local result
    result=$(curl -sf --http1.1 --connect-timeout 15 --max-time 60 \
      -X "$method" "${KC_URL}/admin/realms/${path}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      "$@" 2>/dev/null) && { echo "$result"; return 0; }
    log_warn "kc_api ${method} ${path} attempt ${attempt} failed, retrying..." >&2
    # Force token refresh on retry
    echo "0" > "$_KC_TOKEN_TIME_FILE"
    sleep 2
  done
  log_error "kc_api ${method} ${path} failed after 3 attempts" >&2
  return 1
}

# Idempotent create — returns 0 on success or 409 (already exists)
kc_api_create() {
  local method="$1" path="$2"
  shift 2
  local token http_code attempt
  for attempt in 1 2 3; do
    token=$(kc_get_token)
    http_code=$(curl -s --http1.1 --connect-timeout 15 --max-time 60 -o /dev/null -w "%{http_code}" \
      -X "$method" "${KC_URL}/admin/realms/${path}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      "$@" 2>/dev/null) || true
    case "$http_code" in
      200|201|204) return 0 ;;
      409)         log_info "Resource already exists (409 conflict), skipping"; return 0 ;;
      000|"")      log_warn "Connection dropped or timeout (attempt ${attempt}), retrying..." >&2
                   echo "0" > "$_KC_TOKEN_TIME_FILE"
                   sleep 3 ;;
      *)           die "Keycloak API returned HTTP ${http_code} for ${method} ${path}" ;;
    esac
  done
  die "Keycloak API ${method} ${path} failed after 3 attempts (last HTTP: ${http_code})"
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
# Phase 2: Create platform admin user
###############################################################################
if [[ $PHASE_FROM -le 2 && $PHASE_TO -ge 2 ]]; then
  start_phase "Phase 2: Create Platform Admin User"
  log_info "Creating user '${PLATFORM_ADMIN_USER}'..."
  # Parse first/last name from username (expects firstname.lastname format)
  _admin_first=$(echo "$PLATFORM_ADMIN_USER" | cut -d. -f1 | sed 's/./\U&/')
  _admin_last=$(echo "$PLATFORM_ADMIN_USER" | cut -d. -f2- | sed 's/./\U&/')
  [[ -n "$_admin_last" ]] || _admin_last="Admin"

  # Use jq to safely construct JSON — prevents injection if password contains " or \
  _user_payload=$(jq -n \
    --arg user "$PLATFORM_ADMIN_USER" \
    --arg email "$PLATFORM_ADMIN_EMAIL" \
    --arg first "$_admin_first" \
    --arg last "$_admin_last" \
    --arg pass "$PLATFORM_ADMIN_PASSWORD" \
    '{
      username: $user,
      email: $email,
      firstName: $first,
      lastName: $last,
      enabled: true,
      emailVerified: true,
      credentials: [{type: "password", value: $pass, temporary: false}]
    }')
  # Create user in the platform realm (for OIDC login)
  kc_api_create POST "${KC_REALM}/users" -d "$_user_payload"

  # Get user ID for later group assignment
  PLATFORM_ADMIN_ID=$(kc_api GET "${KC_REALM}/users?username=${PLATFORM_ADMIN_USER}" | jq -r '.[0].id')
  if [[ -z "$PLATFORM_ADMIN_ID" || "$PLATFORM_ADMIN_ID" == "null" ]]; then
    die "Failed to retrieve ${PLATFORM_ADMIN_USER} user ID"
  fi
  log_ok "User ${PLATFORM_ADMIN_USER} created in '${KC_REALM}' realm (ID: ${PLATFORM_ADMIN_ID})"

  # Also create user in master realm with admin role (for Keycloak admin API access)
  log_info "Creating ${PLATFORM_ADMIN_USER} in master realm with admin role..."
  kc_api_create POST "master/users" -d "$_user_payload"

  _master_user_id=$(kc_api GET "master/users?username=${PLATFORM_ADMIN_USER}" | jq -r '.[0].id')
  if [[ -n "$_master_user_id" && "$_master_user_id" != "null" ]]; then
    # Get the admin role ID in master realm
    _admin_role_id=$(kc_api GET "master/roles/admin" | jq -r '.id')
    if [[ -n "$_admin_role_id" && "$_admin_role_id" != "null" ]]; then
      # Assign admin realm role
      _token=$(kc_get_token)
      curl -sk --http1.1 --connect-timeout 15 --max-time 60 -o /dev/null \
        -X POST "${KC_URL}/admin/realms/master/users/${_master_user_id}/role-mappings/realm" \
        -H "Authorization: Bearer ${_token}" \
        -H "Content-Type: application/json" \
        -d '[{"id":"'"${_admin_role_id}"'","name":"admin"}]'
      log_ok "${PLATFORM_ADMIN_USER} granted admin role in master realm"
    else
      log_warn "Could not find admin role in master realm"
    fi
  else
    log_warn "Could not create/find ${PLATFORM_ADMIN_USER} in master realm"
  fi

  # Store platform admin credentials in Vault
  [[ -f "$VAULT_INIT_FILE" ]] || die "Vault init file not found: ${VAULT_INIT_FILE}"
  _root_token="${_root_token:-$(jq -r '.root_token' "$VAULT_INIT_FILE")}"
  vault_exec "$_root_token" kv put kv/services/keycloak/platform-admin \
    username="$PLATFORM_ADMIN_USER" \
    password="$PLATFORM_ADMIN_PASSWORD" \
    email="$PLATFORM_ADMIN_EMAIL"

  end_phase "Phase 2: Create Platform Admin User"
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
    ["traefik-oidc"]="https://traefik.${DOMAIN}/oauth2/callback"
    ["rollouts-oidc"]="https://rollouts.${DOMAIN}/oauth2/callback"
    ["workflows-oidc"]="https://workflows.${DOMAIN}/oauth2/callback"
    ["argocd"]="https://argo.${DOMAIN}/auth/callback"
    ["harbor"]="https://harbor.dev.${DOMAIN}/c/oidc/callback"
    ["gitlab"]="https://gitlab.${DOMAIN}/users/auth/openid_connect/callback"
  )
  # Post-logout redirect URIs — wildcard per service base URL
  # Keycloak's "+" shorthand only matches redirectUris exactly, which breaks
  # logout flows that redirect to / or /login instead of /oauth2/callback
  declare -A CLIENT_LOGOUT_REDIRECTS=(
    ["grafana"]="https://grafana.${DOMAIN}/*"
    ["prometheus-oidc"]="https://prometheus.${DOMAIN}/*"
    ["alertmanager-oidc"]="https://alertmanager.${DOMAIN}/*"
    ["hubble-oidc"]="https://hubble.${DOMAIN}/*"
    ["traefik-oidc"]="https://traefik.${DOMAIN}/*"
    ["rollouts-oidc"]="https://rollouts.${DOMAIN}/*"
    ["workflows-oidc"]="https://workflows.${DOMAIN}/*"
    ["argocd"]="https://argo.${DOMAIN}/*"
    ["harbor"]="https://harbor.dev.${DOMAIN}/*"
    ["gitlab"]="https://gitlab.${DOMAIN}/*"
  )

  # OAuth2-proxy clients need an audience mapper so the token aud claim
  # matches the client_id (oauth2-proxy validates this)
  OAUTH2_PROXY_CLIENTS=(
    prometheus-oidc alertmanager-oidc hubble-oidc
    traefik-oidc rollouts-oidc workflows-oidc
  )

  for client_id in grafana prometheus-oidc alertmanager-oidc hubble-oidc traefik-oidc rollouts-oidc workflows-oidc argocd harbor gitlab; do
    redirect_uri="${CLIENT_REDIRECTS[$client_id]}"
    logout_redirect="${CLIENT_LOGOUT_REDIRECTS[$client_id]}"
    # ArgoCD v2.14 and GitLab omniauth do not send PKCE params — leave empty
    if [[ "$client_id" == "argocd" || "$client_id" == "gitlab" ]]; then
      pkce_method=""
    else
      pkce_method="S256"
    fi
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
        "pkce.code.challenge.method": "'"${pkce_method}"'",
        "login_theme": "",
        "post.logout.redirect.uris": "'"${logout_redirect}"'"
      },
      "defaultClientScopes": ["openid", "profile", "email", "roles", "groups"],
      "optionalClientScopes": []
    }'
    log_ok "OIDC client '${client_id}' created"
  done

  # Add audience mappers to OAuth2-proxy clients (token aud must match client_id)
  log_info "Adding audience mappers to OAuth2-proxy clients..."
  for client_id in "${OAUTH2_PROXY_CLIENTS[@]}"; do
    _client_uuid=$(kc_api GET "${KC_REALM}/clients?clientId=${client_id}" | jq -r '.[0].id')
    if [[ -z "$_client_uuid" || "$_client_uuid" == "null" ]]; then
      log_warn "Could not find client UUID for ${client_id} — skipping audience mapper"
      continue
    fi
    kc_api_create POST "${KC_REALM}/clients/${_client_uuid}/protocol-mappers/models" -d '{
      "name": "audience-mapper",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-audience-mapper",
      "config": {
        "included.client.audience": "'"${client_id}"'",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "included.custom.audience": "",
        "userinfo.token.claim": "false"
      }
    }'
    log_ok "Audience mapper added to '${client_id}'"
  done

  # Disable SSO — set short realm SSO session so each service requires
  # independent login. Combined with --prompt=login on all OAuth2-proxies.
  # Timeouts must be long enough for OAuth authorization code flow to complete.
  log_info "Configuring realm session timeouts (SSO enabled across all services)..."
  kc_api PUT "${KC_REALM}" -d '{
    "ssoSessionIdleTimeout": 28800,
    "ssoSessionMaxLifespan": 36000,
    "accessTokenLifespan": 300,
    "accessCodeLifespan": 120
  }'
  log_ok "SSO session: 8h idle / 10h max (single sign-on across all platform services)"

  # Retrieve generated client secrets and seed them into Vault
  log_info "Seeding OIDC client secrets into Vault..."
  [[ -f "$VAULT_INIT_FILE" ]] || die "Vault init file not found: ${VAULT_INIT_FILE}"
  _root_token="${_root_token:-$(jq -r '.root_token' "$VAULT_INIT_FILE")}"

  for client_id in grafana prometheus-oidc alertmanager-oidc hubble-oidc traefik-oidc rollouts-oidc workflows-oidc argocd harbor gitlab; do
    # Get the internal client UUID from Keycloak
    _client_uuid=$(kc_api GET "${KC_REALM}/clients?clientId=${client_id}" | jq -r '.[0].id')
    if [[ -z "$_client_uuid" || "$_client_uuid" == "null" ]]; then
      log_warn "Could not find client UUID for ${client_id} — skipping Vault seed"
      continue
    fi

    # Get the auto-generated client secret (retry up to 3 times)
    _client_secret=""
    for _secret_attempt in 1 2 3; do
      _client_secret=$(kc_api GET "${KC_REALM}/clients/${_client_uuid}/client-secret" | jq -r '.value') || true
      if [[ -n "$_client_secret" && "$_client_secret" != "null" ]]; then
        break
      fi
      log_warn "Attempt ${_secret_attempt}: empty client secret for ${client_id}, retrying..."
      sleep 2
    done
    if [[ -z "$_client_secret" || "$_client_secret" == "null" ]]; then
      die "Could not retrieve client secret for ${client_id} after 3 attempts"
    fi

    # Generate a cookie-secret for OAuth2-proxy (16-byte hex = 32 hex chars)
    _cookie_secret=$(openssl rand -hex 16)

    # Seed into Vault at kv/oidc/<client-id>
    vault_exec "$_root_token" kv put "kv/oidc/${client_id}" \
      client-secret="$_client_secret" \
      cookie-secret="$_cookie_secret"

    # Verify secret was written correctly (read back and validate non-empty)
    _verify_secret=$(vault_get_field "$_root_token" "kv/oidc/${client_id}" "client-secret" 2>/dev/null) || true
    if [[ -z "$_verify_secret" ]]; then
      die "Vault verification failed: kv/oidc/${client_id} client-secret is empty after write"
    fi

    # For GitLab: also write the OIDC provider JSON to services/gitlab/oidc-secret
    if [[ "$client_id" == "gitlab" ]]; then
      _gitlab_provider=$(jq -nc \
        --arg secret "$_client_secret" \
        --arg domain "$DOMAIN" \
        --arg realm "$KC_REALM" \
        '{
          name: "openid_connect",
          label: "Keycloak",
          args: {
            name: "openid_connect",
            scope: ["openid","profile","email","groups"],
            response_type: "code",
            issuer: ("https://keycloak." + $domain + "/realms/" + $realm),
            discovery: true,
            client_auth_method: "query",
            uid_field: "preferred_username",
            pkce: true,
            client_options: {
              identifier: "gitlab",
              secret: $secret,
              redirect_uri: ("https://gitlab." + $domain + "/users/auth/openid_connect/callback")
            }
          }
        }')
      vault_exec "$_root_token" kv put "kv/services/gitlab/oidc-secret" \
        "provider=${_gitlab_provider}"
      log_ok "Seeded Vault kv/services/gitlab/oidc-secret"
    fi

    log_ok "Seeded Vault kv/oidc/${client_id}"
  done

  # Create Vault policies and K8s auth roles for ESO in namespaces that need OIDC secrets
  # monitoring: prometheus, alertmanager, grafana OAuth2-proxy + Grafana OIDC
  # kube-system: hubble OAuth2-proxy (Cilium observability UI lives in kube-system)
  log_info "Creating Vault policies for ESO..."
  kubectl exec -i -n vault vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 \
    VAULT_TOKEN="$_root_token" \
    vault policy write eso-monitoring - <<POLICY
path "kv/data/oidc/*" {
  capabilities = ["read"]
}
path "kv/metadata/oidc/*" {
  capabilities = ["read", "list"]
}
path "kv/data/services/database/grafana-pg" {
  capabilities = ["read"]
}
path "kv/metadata/services/database/grafana-pg" {
  capabilities = ["read", "list"]
}
POLICY

  kubectl exec -i -n vault vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 \
    VAULT_TOKEN="$_root_token" \
    vault policy write eso-kube-system - <<POLICY
path "kv/data/oidc/*" {
  capabilities = ["read"]
}
path "kv/metadata/oidc/*" {
  capabilities = ["read", "list"]
}
POLICY

  log_info "Creating Vault K8s auth roles for ESO..."
  vault_exec "$_root_token" write auth/kubernetes/role/eso-monitoring \
    bound_service_account_names=eso-secrets \
    bound_service_account_namespaces=monitoring \
    policies=eso-monitoring \
    ttl=1h

  vault_exec "$_root_token" write auth/kubernetes/role/eso-kube-system \
    bound_service_account_names=eso-secrets \
    bound_service_account_namespaces=kube-system \
    policies=eso-kube-system \
    ttl=1h

  # Create namespaces, service accounts, and SecretStores
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

  for ns in monitoring kube-system; do
    kubectl create serviceaccount eso-secrets -n "$ns" \
      --dry-run=client -o yaml | kubectl apply -f -

    _eso_role="eso-${ns}"
    kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: ${ns}
spec:
  provider:
    vault:
      server: http://vault.vault.svc.cluster.local:8200
      path: kv
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: ${_eso_role}
          serviceAccountRef:
            name: eso-secrets
EOF
  done

  # Apply ExternalSecrets for OAuth2-proxy and Grafana OIDC
  log_info "Applying OIDC ExternalSecrets..."
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/external-secret-prometheus.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/external-secret-alertmanager.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/external-secret-hubble.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/external-secret-grafana.yaml"

  log_ok "OIDC secrets seeded in Vault and ExternalSecrets applied"

  end_phase "Phase 3: Create OIDC Clients"
fi

###############################################################################
# Phase 4: Create groups and assign breakglass user
###############################################################################
if [[ $PHASE_FROM -le 4 && $PHASE_TO -ge 4 ]]; then
  start_phase "Phase 4: Create Groups + Assign Platform Admin"

  log_info "Creating group 'platform-admins'..."
  kc_api_create POST "${KC_REALM}/groups" -d '{"name": "platform-admins"}'

  GROUP_ID=$(kc_api GET "${KC_REALM}/groups?search=platform-admins" | jq -r '.[0].id')
  if [[ -z "$GROUP_ID" || "$GROUP_ID" == "null" ]]; then
    die "Failed to retrieve platform-admins group ID"
  fi
  log_ok "Group platform-admins created (ID: ${GROUP_ID})"

  # Retrieve platform admin user ID (in case phase 2 was run separately)
  PLATFORM_ADMIN_ID=$(kc_api GET "${KC_REALM}/users?username=${PLATFORM_ADMIN_USER}" | jq -r '.[0].id')
  if [[ -z "$PLATFORM_ADMIN_ID" || "$PLATFORM_ADMIN_ID" == "null" ]]; then
    die "${PLATFORM_ADMIN_USER} user not found. Run phase 2 first."
  fi

  log_info "Assigning ${PLATFORM_ADMIN_USER} to platform-admins..."
  kc_api_create PUT "${KC_REALM}/users/${PLATFORM_ADMIN_ID}/groups/${GROUP_ID}"
  log_ok "${PLATFORM_ADMIN_USER} assigned to platform-admins"

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

  # Assign the groups scope as a default scope on all OIDC clients
  _groups_scope_id=$(kc_api GET "${KC_REALM}/client-scopes" | jq -r '.[] | select(.name=="groups") | .id')
  if [[ -n "$_groups_scope_id" && "$_groups_scope_id" != "null" ]]; then
    for client_id in grafana prometheus-oidc alertmanager-oidc hubble-oidc traefik-oidc rollouts-oidc workflows-oidc argocd harbor gitlab; do
      _client_uuid=$(kc_api GET "${KC_REALM}/clients?clientId=${client_id}" | jq -r '.[0].id')
      if [[ -n "$_client_uuid" && "$_client_uuid" != "null" ]]; then
        _assign_token=$(kc_get_token)
        curl -sk --http1.1 --connect-timeout 15 --max-time 60 -o /dev/null \
          -X PUT "${KC_URL}/admin/realms/${KC_REALM}/clients/${_client_uuid}/default-client-scopes/${_groups_scope_id}" \
          -H "Authorization: Bearer ${_assign_token}"
        log_ok "Assigned groups scope to ${client_id}"
      fi
    done
  else
    log_warn "Could not find groups scope ID — skipping scope assignment"
  fi

  end_phase "Phase 4: Create Groups + Assign Breakglass User"
fi

###############################################################################
# Phase 5: Configure prompt=login authentication flow
###############################################################################
if [[ $PHASE_FROM -le 5 && $PHASE_TO -ge 5 ]]; then
  start_phase "Phase 5: Configure Authentication Flow"

  # Copy the built-in browser flow to a custom flow
  log_info "Copying browser flow to 'browser-prompt-login'..."

  # Check if custom flow already exists
  CUSTOM_FLOW=$(kc_api GET "${KC_REALM}/authentication/flows" \
    | jq -r '.[] | select(.alias == "browser-prompt-login") | .id')

  if [[ -n "$CUSTOM_FLOW" && "$CUSTOM_FLOW" != "null" ]]; then
    log_info "Custom flow browser-prompt-login already exists, skipping copy"
  else
    BROWSER_FLOW=$(kc_api GET "${KC_REALM}/authentication/flows" \
      | jq -r '.[] | select(.alias == "browser") | .id')
    if [[ -z "$BROWSER_FLOW" || "$BROWSER_FLOW" == "null" ]]; then
      log_warn "Could not find built-in browser flow — skipping custom flow setup"
    else
      # Try to copy the browser flow (some Keycloak versions use different API paths)
      _copy_token=$(kc_get_token)
      _copy_code=$(curl -s --connect-timeout 15 --max-time 60 -o /dev/null -w "%{http_code}" \
        -X POST "${KC_URL}/admin/realms/${KC_REALM}/authentication/flows/${BROWSER_FLOW}/copy" \
        -H "Authorization: Bearer ${_copy_token}" \
        -H "Content-Type: application/json" \
        -d '{"newName": "browser-prompt-login"}')
      case "$_copy_code" in
        200|201|204) log_ok "Browser flow copied successfully" ;;
        409)         log_info "Custom flow already exists (409)" ;;
        *)           log_warn "Could not copy browser flow (HTTP ${_copy_code}) — non-critical, skipping" ;;
      esac
    fi
  fi

  # Set the custom flow as the realm browser flow (idempotent)
  log_info "Setting browser-prompt-login as realm browser flow..."
  kc_api PUT "${KC_REALM}" -d '{
    "browserFlow": "browser-prompt-login"
  }' || log_warn "Could not set browser flow (may already be set)"

  log_ok "Authentication flow configured"
  end_phase "Phase 5: Configure Authentication Flow"
fi

###############################################################################
# Phase 6: Validation
###############################################################################
if [[ $PHASE_FROM -le 6 && $PHASE_TO -ge 6 ]]; then
  start_phase "Phase 6: Validation"
  log_ok "Keycloak setup complete"
  log_info "Realm: ${KC_REALM}"
  log_info "Platform admin: ${PLATFORM_ADMIN_USER}"
  log_info "OIDC clients: grafana, prometheus-oidc, alertmanager-oidc, hubble-oidc, argocd, harbor, gitlab"
  log_info "Groups: platform-admins"
  log_info "Auth flow: browser-prompt-login (forces re-authentication)"
  log_info ""
  log_info "OIDC client secrets have been seeded in Vault (kv/oidc/<client-id>)"
  log_info "ExternalSecrets applied — ESO will sync secrets to K8s"
  log_info ""
  log_info "Next steps:"
  log_info "  1. Run deploy-keycloak.sh --phase 7 to deploy OAuth2-proxy instances"
  log_info "  2. Helm upgrade kube-prometheus-stack to pick up real Grafana OIDC secret"
  end_phase "Phase 6: Validation"
fi
