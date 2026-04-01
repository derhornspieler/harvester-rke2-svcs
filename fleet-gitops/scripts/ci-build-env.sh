#!/usr/bin/env bash
# ci-build-env.sh — Synthesize .env from Vault secrets for CI pipeline.
#
# Authenticates to Vault via GitLab JWT, reads fleet-deploy credentials,
# and builds a complete .env from .env.example defaults.
#
# Required environment variables:
#   VAULT_ID_TOKEN — GitLab JWT id_token (from id_tokens block)
#   VAULT_ADDR     — Vault server URL (e.g., https://vault.<DOMAIN>)
#   DOMAIN         — Base domain (group-level CI variable)
#   BUNDLE_VERSION — From compute-version job dotenv artifact
#
# Output: fleet-gitops/.env (ready for render/push/deploy scripts)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FLEET_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

# --- Authenticate to Vault ---
log "[INFO] Authenticating to Vault..."

# Use CA cert if available, fall back to -k for self-signed
CA_FLAG=""
if [[ -f /etc/ssl/certs/vault-root-ca.pem ]]; then
  CA_FLAG="--cacert /etc/ssl/certs/vault-root-ca.pem"
elif [[ -n "${GIT_SSL_CAINFO:-}" && -f "${GIT_SSL_CAINFO}" ]]; then
  CA_FLAG="--cacert ${GIT_SSL_CAINFO}"
else
  CA_FLAG="-k"
  log "[WARN] No CA cert found — using insecure TLS"
fi

VAULT_RESP=$(curl -s -w "\n%{http_code}" \
  ${CA_FLAG} \
  --request POST \
  --data "{\"jwt\": \"${VAULT_ID_TOKEN}\", \"role\": \"gitlab-ci-fleet-deploy\"}" \
  "${VAULT_ADDR}/v1/auth/jwt/login" 2>&1)
VAULT_HTTP=$(echo "${VAULT_RESP}" | tail -1)
VAULT_BODY=$(echo "${VAULT_RESP}" | sed '$d')
log "[INFO] Vault auth response: HTTP ${VAULT_HTTP}"

if [[ "${VAULT_HTTP}" != "200" ]]; then
  log "[ERROR] Vault JWT auth failed (HTTP ${VAULT_HTTP})"
  echo "${VAULT_BODY}" | head -5 >&2
  exit 1
fi

VAULT_TOKEN=$(echo "${VAULT_BODY}" | jq -r '.auth.client_token')
if [[ -z "${VAULT_TOKEN}" || "${VAULT_TOKEN}" == "null" ]]; then
  log "[ERROR] Failed to extract Vault token"
  exit 1
fi
log "[INFO] Vault auth successful"

# --- Read fleet-deploy credentials ---
log "[INFO] Reading fleet-deploy credentials from Vault..."
CREDS_RESP=$(curl -s -w "\n%{http_code}" \
  ${CA_FLAG} \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "${VAULT_ADDR}/v1/kv/data/services/ci/fleet-deploy" 2>&1)
CREDS_HTTP=$(echo "${CREDS_RESP}" | tail -1)
CREDS=$(echo "${CREDS_RESP}" | sed '$d')
log "[INFO] Vault read response: HTTP ${CREDS_HTTP}"
if [[ "${CREDS_HTTP}" != "200" ]]; then
  log "[ERROR] Failed to read fleet-deploy credentials (HTTP ${CREDS_HTTP})"
  echo "${CREDS}" | head -5 >&2
  exit 1
fi

RANCHER_URL=$(echo "${CREDS}" | jq -r '.data.data["rancher-url"]')
RANCHER_TOKEN=$(echo "${CREDS}" | jq -r '.data.data["rancher-token"]')
HARBOR_USER=$(echo "${CREDS}" | jq -r '.data.data["harbor-user"]')
HARBOR_PASS=$(echo "${CREDS}" | jq -r '.data.data["harbor-pass"]')

if [[ -z "${RANCHER_URL}" || "${RANCHER_URL}" == "null" ]]; then
  log "[ERROR] Could not read fleet-deploy credentials from Vault"
  exit 1
fi
log "[INFO] Credentials loaded"

# --- Build .env from .env.example ---
log "[INFO] Building .env from .env.example..."
# Comment out lines with <PLACEHOLDER> syntax that bash would interpret as
# input redirection (e.g., git@github.com:<USER>/<REPO>.git)
sed 's/=.*<[A-Z_]*>.*/=""/' "${FLEET_DIR}/.env.example" > "${FLEET_DIR}/.env"

# Inject secrets and variables
{
  echo ""
  echo "# === CI-injected values ==="
  echo "DOMAIN='${DOMAIN}'"
  echo "HARBOR_HOST='harbor.${DOMAIN}'"
  echo "RANCHER_URL='${RANCHER_URL}'"
  echo "RANCHER_TOKEN='${RANCHER_TOKEN}'"
  echo "HARBOR_USER='${HARBOR_USER}'"
  echo "HARBOR_PASS='${HARBOR_PASS}'"
  # Get BUNDLE_VERSION from latest git tag (no artifact dependency)
  if [[ -z "${BUNDLE_VERSION:-}" ]]; then
    git fetch --tags origin 2>/dev/null || true
    LATEST_TAG=$(git tag -l 'bundle-v*' --sort=-v:refname 2>/dev/null | head -1)
    BUNDLE_VERSION="${LATEST_TAG#bundle-v}"
    BUNDLE_VERSION="${BUNDLE_VERSION:-1.0.0}"
  fi
  echo "BUNDLE_VERSION='${BUNDLE_VERSION}'"
  echo "ROOT_CA_PEM_FILE='./root-ca.pem'"
} >> "${FLEET_DIR}/.env"

log "[INFO] .env ready at ${FLEET_DIR}/.env"
