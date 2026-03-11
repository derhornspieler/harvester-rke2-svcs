#!/usr/bin/env bash
# init-lib.sh — Shared functions for per-service init Jobs
# Sourced by each <service>-init Job via ConfigMap volume mount.
#
# Each init bundle embeds a copy of this file as a ConfigMap.
# The canonical source is fleet-gitops/scripts/init-lib.sh.
#
# Usage in init Job:
#   source /init-lib/init-lib.sh
#   vault_k8s_login "bootstrap-keycloak-${NAMESPACE}"
#   ...
set -euo pipefail

log()  { echo "[$(date +%H:%M:%S)] $*" >&2; }

#######################################################################
# Vault Authentication (K8s auth — NEVER use root token)
#######################################################################
vault_k8s_login() {
  local role="$1"
  local sa_token
  sa_token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  VAULT_TOKEN=$(vault write -field=token auth/kubernetes/login \
    role="${role}" jwt="${sa_token}")
  export VAULT_TOKEN
  log "[INFO] Authenticated to Vault as role: ${role}"
}

#######################################################################
# Vault KV — get or generate secrets (returns value, does NOT write)
# Caller must vault_kv_put separately to persist generated values.
#######################################################################
vault_get_or_generate() {
  local path="$1"
  local property="$2"
  local length="${3:-32}"

  local existing
  existing=$(vault kv get -field="${property}" "kv/${path}" 2>/dev/null || true)
  if [[ -n "${existing}" ]]; then
    echo "${existing}"
    return 0
  fi

  # Generate new random value
  tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "${length}"
}

vault_kv_put() {
  local path="$1"
  shift
  vault kv put "kv/${path}" "$@"
  log "[INFO] Written to kv/${path}"
}

#######################################################################
# Vault Policy — bind pre-created policies to auth roles
# Called by init Jobs to set up ESO reader/writer for their namespace.
#######################################################################
vault_bind_eso_roles() {
  local namespace="$1"
  local sa_name="${2:-eso-secrets}"

  vault write "auth/kubernetes/role/eso-reader-${namespace}" \
    bound_service_account_names="${sa_name}" \
    bound_service_account_namespaces="${namespace}" \
    policies="eso-reader-${namespace}" \
    ttl=1h

  vault write "auth/kubernetes/role/eso-writer-${namespace}" \
    bound_service_account_names="${sa_name}" \
    bound_service_account_namespaces="${namespace}" \
    policies="eso-writer-${namespace}" \
    ttl=1h

  log "[INFO] Bound ESO roles for namespace: ${namespace}"
}

#######################################################################
# Create namespace SecretStore (reader + writer) for ESO
#######################################################################
vault_create_secretstore() {
  local namespace="$1"
  local vault_url="${VAULT_ADDR:-http://vault.vault.svc.cluster.local:8200}"

  kubectl apply -f - <<SSEOF
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: ${namespace}
spec:
  provider:
    vault:
      server: "${vault_url}"
      path: kv
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: "eso-reader-${namespace}"
          serviceAccountRef:
            name: eso-secrets
---
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: vault-writer
  namespace: ${namespace}
spec:
  provider:
    vault:
      server: "${vault_url}"
      path: kv
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: "eso-writer-${namespace}"
          serviceAccountRef:
            name: eso-secrets
SSEOF
  log "[INFO] Created SecretStores (reader + writer) in namespace: ${namespace}"
}

#######################################################################
# Keycloak OIDC Client — upsert via REST API
# Uses --http1.1 to avoid Traefik HTTP/2 multiplexing issues.
#######################################################################
keycloak_create_oidc_client() {
  local client_id="$1"
  local redirect_uri="$2"
  local pkce="${3:-S256}"  # S256 or disabled
  local keycloak_url="${KEYCLOAK_URL}"
  local admin_pass
  admin_pass=$(cat /secrets/keycloak-admin-password 2>/dev/null || echo "${KEYCLOAK_ADMIN_PASS:-}")

  # Get admin token (password grant only)
  local token
  token=$(curl -s --http1.1 -X POST \
    "${keycloak_url}/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=admin-cli" \
    -d "username=admin&password=${admin_pass}" \
    | jq -r '.access_token')

  if [[ -z "${token}" || "${token}" == "null" ]]; then
    log "[ERROR] Failed to get Keycloak admin token"
    return 1
  fi

  local realm="platform"
  local api="${keycloak_url}/admin/realms/${realm}/clients"

  # Check if client exists
  local existing_id
  existing_id=$(curl -s --http1.1 -H "Authorization: Bearer ${token}" \
    "${api}?clientId=${client_id}" \
    | jq -r '.[0].id // empty' 2>/dev/null || true)

  # Generate or retrieve client secret
  local client_secret
  client_secret=$(vault_get_or_generate "oidc/${client_id}" "client-secret")

  local cookie_secret
  cookie_secret=$(vault_get_or_generate "oidc/${client_id}" "cookie-secret" 16)

  # Build client JSON
  local pkce_attrs=""
  if [[ "${pkce}" == "S256" ]]; then
    pkce_attrs=',"pkce.code.challenge.method": "S256"'
  fi

  local post_logout
  post_logout="${redirect_uri%/*}/*"

  local client_json
  client_json=$(jq -n \
    --arg clientId "${client_id}" \
    --arg secret "${client_secret}" \
    --arg redirectUri "${redirect_uri}" \
    --arg postLogout "${post_logout}" \
    --argjson pkce "${pkce_attrs:-null}" \
    '{
      clientId: $clientId,
      enabled: true,
      protocol: "openid-connect",
      publicClient: false,
      secret: $secret,
      redirectUris: [$redirectUri],
      webOrigins: ["+"],
      standardFlowEnabled: true,
      directAccessGrantsEnabled: false,
      attributes: {
        "post.logout.redirect.uris": $postLogout
      }
    }')

  # Add PKCE attribute if enabled
  if [[ "${pkce}" == "S256" ]]; then
    client_json=$(echo "${client_json}" | jq '.attributes["pkce.code.challenge.method"] = "S256"')
  fi

  if [[ -n "${existing_id}" ]]; then
    curl -s --http1.1 -X PUT -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      "${api}/${existing_id}" -d "${client_json}" >/dev/null
    log "[INFO] Updated OIDC client: ${client_id}"
  else
    curl -s --http1.1 -X POST -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      "${api}" -d "${client_json}" >/dev/null
    log "[INFO] Created OIDC client: ${client_id}"
  fi

  # Store in Vault
  vault_kv_put "oidc/${client_id}" \
    client-secret="${client_secret}" \
    cookie-secret="${cookie_secret}"
}

#######################################################################
# MinIO Bucket + IAM User — upsert via mc CLI
# Uses IAM users with scoped policies (NOT svcacct which inherits root)
#######################################################################
minio_setup_alias() {
  local minio_url="${MINIO_ENDPOINT}"
  local root_user root_pass
  root_user=$(cat /secrets/minio-root-user 2>/dev/null || echo "${MINIO_ROOT_USER:-}")
  root_pass=$(cat /secrets/minio-root-password 2>/dev/null || echo "${MINIO_ROOT_PASSWORD:-}")

  mc alias set myminio "${minio_url}" "${root_user}" "${root_pass}" --api S3v4
  log "[INFO] MinIO alias configured"
}

minio_create_bucket() {
  local bucket="$1"
  mc mb --ignore-existing "myminio/${bucket}"
  log "[INFO] Ensured bucket exists: ${bucket}"
}

minio_create_service_user() {
  local user_name="$1"
  local bucket_prefix="$2"  # e.g. "harbor" or "gitlab-*"
  local vault_path="$3"

  # Check if credentials already exist in Vault
  local access_key secret_key
  access_key=$(vault kv get -field=access-key "kv/${vault_path}" 2>/dev/null || true)
  secret_key=$(vault kv get -field=secret-key "kv/${vault_path}" 2>/dev/null || true)

  if [[ -n "${access_key}" && -n "${secret_key}" ]]; then
    if mc admin user info myminio "${access_key}" >/dev/null 2>&1; then
      log "[INFO] MinIO user already exists for: ${user_name}"
      return 0
    fi
  fi

  # Generate credentials
  access_key=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 20)
  secret_key=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 40)

  # Create IAM user
  mc admin user add myminio "${access_key}" "${secret_key}"

  # Create scoped IAM policy (matches existing minio-init pattern)
  local policy_json
  policy_json=$(jq -n \
    --arg prefix "${bucket_prefix}" \
    '{
      Version: "2012-10-17",
      Statement: [{
        Effect: "Allow",
        Action: ["s3:*"],
        Resource: [
          ("arn:aws:s3:::" + $prefix),
          ("arn:aws:s3:::" + $prefix + "/*")
        ]
      }]
    }')

  echo "${policy_json}" | mc admin policy create myminio "${user_name}-policy" /dev/stdin
  mc admin policy attach myminio "${user_name}-policy" --user "${access_key}"

  # Store in Vault
  vault_kv_put "${vault_path}" \
    access-key="${access_key}" \
    secret-key="${secret_key}"

  log "[INFO] Created MinIO IAM user: ${user_name}"
}
