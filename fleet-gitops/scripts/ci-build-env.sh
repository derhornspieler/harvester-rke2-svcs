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
VAULT_RESP=$(curl -sf \
  --cacert /etc/ssl/certs/vault-root-ca.pem \
  --request POST \
  --data "{\"jwt\": \"${VAULT_ID_TOKEN}\", \"role\": \"gitlab-ci-fleet-deploy\"}" \
  "${VAULT_ADDR}/v1/auth/jwt/login" 2>&1)

VAULT_TOKEN=$(echo "${VAULT_RESP}" | jq -r '.auth.client_token')
if [[ -z "${VAULT_TOKEN}" || "${VAULT_TOKEN}" == "null" ]]; then
  log "[ERROR] Vault JWT auth failed"
  echo "${VAULT_RESP}" | head -5 >&2
  exit 1
fi
log "[INFO] Vault auth successful"

# --- Read fleet-deploy credentials ---
log "[INFO] Reading fleet-deploy credentials from Vault..."
CREDS=$(curl -sf \
  --cacert /etc/ssl/certs/vault-root-ca.pem \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "${VAULT_ADDR}/v1/kv/data/services/ci/fleet-deploy" 2>&1)

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
cp "${FLEET_DIR}/.env.example" "${FLEET_DIR}/.env"

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
  echo "BUNDLE_VERSION='${BUNDLE_VERSION:-1.0.0}'"
  echo "ROOT_CA_PEM_FILE='./root-ca.pem'"
} >> "${FLEET_DIR}/.env"

log "[INFO] .env ready at ${FLEET_DIR}/.env"
