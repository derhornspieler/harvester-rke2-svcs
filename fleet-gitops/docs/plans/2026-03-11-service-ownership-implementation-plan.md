# Service Ownership Model — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development
> (if subagents available) or superpowers:executing-plans to implement this plan.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor Fleet GitOps so each service owns its external dependencies
via per-service init Jobs, replacing three monolithic init Jobs.

**Architecture:** Three-layer model — Layer 0 (minimal vault-init +
keycloak-realm-init), Layer 1 (per-service init Jobs), Layer 2 (declarative
manifests). ClusterSecretStore for bootstrap, namespace SecretStores for
services. MinimalCD via ArgoCD ApplicationSet for developer apps.

**Tech Stack:** Vault (K8s auth), ESO (PushSecret/ExternalSecret),
Keycloak (REST API), MinIO (`mc` CLI), Fleet HelmOps, ArgoCD ApplicationSets,
Argo Rollouts, Argo Workflows.

**Design spec:** `docs/plans/2026-03-11-service-ownership-model-design.md`

---

## Phase Overview

This refactor is split into 9 phases. Each phase is independently deployable
and testable via `deploy.sh --delete && deploy.sh`. Phases must be implemented
in order — each builds on the previous.

| Phase | Name | Scope | Depends On |
|-------|------|-------|------------|
| 1 | Vault-Init Minimal | Shrink vault-init, add ClusterSecretStore, pre-create policies | None |
| 2 | Shared Init Library | ConfigMap with shell functions for Vault/Keycloak/MinIO ops | Phase 1 |
| 3 | Keycloak Realm Init | Extract realm + 5 infra clients from keycloak-config | Phase 1 |
| 4 | 11-Infra-Auth Bundle | Extract Traefik/Hubble/Vault oauth2-proxy from monitoring | Phase 3 |
| 5 | Per-Service Init Jobs (Identity + Monitoring) | keycloak-init, grafana-init, prometheus-init, alertmanager-init, loki-init, alloy-init | Phase 2, 3 |
| 6 | Per-Service Init Jobs (Harbor) | harbor-init, minio-init removal | Phase 2, 3 |
| 7 | Per-Service Init Jobs (GitOps) | argocd-init, rollouts-init, workflows-init | Phase 2, 3 |
| 8 | Per-Service Init Jobs (GitLab) | gitlab-init, runners | Phase 2, 3, 6 |
| 9 | MinimalCD Developer Experience | platform-deployments repo, ApplicationSet, templates | Phase 4, 7 |

**After each phase:** Run `deploy.sh --delete && deploy.sh` to validate.
All existing services must deploy and function correctly.

---

## Chunk 1: Phase 1 — Vault-Init Minimal

### Task 1.1: Create Pre-Created Template Policies

**Files:**
- Modify: `fleet-gitops/05-pki-secrets/vault-init/manifests/vault-init-job.yaml`

Current vault-init creates ~15 per-namespace ESO policies inline. Refactor to:
1. Pre-create `eso-reader-<ns>` and `eso-writer-<ns>` policies for all namespaces
2. Create scoped bootstrap auth roles (`bootstrap-base-<ns>`,
   `bootstrap-keycloak-<ns>`, `bootstrap-minio-<ns>`)
3. Keep PKI, KV v2, K8s auth backend creation unchanged

- [ ] **Step 1: Read current vault-init-job.yaml**

Read `/home/rocky/data/harvester-rke2-svcs/fleet-gitops/05-pki-secrets/vault-init/manifests/vault-init-job.yaml`
and identify the ESO namespace list (line ~289) and policy creation logic (lines ~272-332).

- [ ] **Step 2: Add pre-created template policies**

After the existing ESO policy loop, add policy creation for each namespace:

```bash
# Pre-create template policies for per-service init Jobs
for ns in "${ESO_NAMESPACES[@]}"; do
  # eso-reader policy (read-only to service's own KV path)
  vault policy write "eso-reader-${ns}" - <<POLICY
path "kv/data/services/${ns}/*" {
  capabilities = ["read", "list"]
}
path "kv/metadata/services/${ns}/*" {
  capabilities = ["read", "list"]
}
POLICY

  # eso-writer policy (write to service's own KV path)
  vault policy write "eso-writer-${ns}" - <<POLICY
path "kv/data/services/${ns}/*" {
  capabilities = ["create", "update", "read", "list"]
}
path "kv/metadata/services/${ns}/*" {
  capabilities = ["read", "list", "delete"]
}
POLICY
done
```

- [ ] **Step 3: Add scoped bootstrap auth roles**

For each namespace, create bootstrap roles with scoped admin credential access:

```bash
# Bootstrap roles — scoped per dependency type
for ns in "${ESO_NAMESPACES[@]}"; do
  # Base bootstrap (Vault-only services)
  vault write "auth/kubernetes/role/bootstrap-base-${ns}" \
    bound_service_account_names="${ns}-init" \
    bound_service_account_namespaces="${ns}" \
    policies="eso-reader-${ns},eso-writer-${ns}" \
    ttl=1h

  # Bootstrap + Keycloak admin access
  vault write "auth/kubernetes/role/bootstrap-keycloak-${ns}" \
    bound_service_account_names="${ns}-init" \
    bound_service_account_namespaces="${ns}" \
    policies="eso-reader-${ns},eso-writer-${ns},admin-keycloak-reader" \
    ttl=1h

  # Bootstrap + MinIO admin access
  vault write "auth/kubernetes/role/bootstrap-minio-${ns}" \
    bound_service_account_names="${ns}-init" \
    bound_service_account_namespaces="${ns}" \
    policies="eso-reader-${ns},eso-writer-${ns},admin-minio-reader" \
    ttl=1h
done

# Admin credential reader policies (scoped)
vault policy write "admin-keycloak-reader" - <<POLICY
path "kv/data/admin/keycloak" {
  capabilities = ["read"]
}
POLICY

vault policy write "admin-minio-reader" - <<POLICY
path "kv/data/admin/minio" {
  capabilities = ["read"]
}
POLICY
```

- [ ] **Step 4: Seed admin credentials to Vault KV**

Add at end of vault-init, after existing credential seeding:

```bash
# Seed Keycloak admin password (read by keycloak-init Job)
KEYCLOAK_ADMIN_PASS=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 32)
vault kv put kv/admin/keycloak \
  admin-password="${KEYCLOAK_ADMIN_PASS}"

# Seed MinIO root credentials (read by harbor-init, gitlab-init Jobs)
MINIO_ROOT_USER="minio-admin"
MINIO_ROOT_PASS=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 32)
vault kv put kv/admin/minio \
  root-user="${MINIO_ROOT_USER}" \
  root-password="${MINIO_ROOT_PASS}"
```

Note: Use `vault kv get` first to check if already exists (idempotent).
Follow existing `vault_get_or_generate` pattern.

- [ ] **Step 5: Fix Vault OIDC default role (security bug)**

In the OIDC auth configuration section, remove `admin-policy` from the
`default` role:

```bash
# BEFORE (vulnerable — gives all users admin access):
vault write auth/oidc/role/default \
  policies="default,admin-policy" ...

# AFTER (fixed — default users get default policy only):
vault write auth/oidc/role/default \
  policies="default" ...
```

The `admin` role (restricted to `platform-admins` group) keeps `admin-policy`.

- [ ] **Step 6: Commit**

```bash
git add fleet-gitops/05-pki-secrets/vault-init/manifests/vault-init-job.yaml
git commit -m "refactor: vault-init pre-create template policies and bootstrap roles"
```

### Task 1.2: Create ClusterSecretStore for Bootstrap

**Files:**
- Create: `fleet-gitops/05-pki-secrets/vault-init/manifests/cluster-secret-store-bootstrap.yaml`

- [ ] **Step 1: Create ClusterSecretStore manifest**

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-bootstrap
spec:
  provider:
    vault:
      server: ${VAULT_INTERNAL_URL}
      path: kv
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: bootstrap-cluster-reader
          serviceAccountRef:
            name: eso-secrets
            namespace: external-secrets
```

- [ ] **Step 2: Add bootstrap-cluster-reader Vault role in vault-init**

In vault-init-job.yaml, add:

```bash
# ClusterSecretStore needs a cluster-wide reader for admin creds
vault write "auth/kubernetes/role/bootstrap-cluster-reader" \
  bound_service_account_names="eso-secrets" \
  bound_service_account_namespaces="external-secrets" \
  policies="admin-keycloak-reader,admin-minio-reader" \
  ttl=1h
```

- [ ] **Step 3: Commit**

```bash
git add fleet-gitops/05-pki-secrets/vault-init/manifests/cluster-secret-store-bootstrap.yaml
git add fleet-gitops/05-pki-secrets/vault-init/manifests/vault-init-job.yaml
git commit -m "feat: add ClusterSecretStore for bootstrap credential access"
```

### Task 1.3: Update deploy-fleet-helmops.sh Dependencies

**Files:**
- Modify: `fleet-gitops/scripts/deploy-fleet-helmops.sh`

No new HelmOps needed for Phase 1. The vault-init changes are within the
existing bundle. But verify the HELMOP_DEFS still work.

- [ ] **Step 1: Verify no dependency changes needed**

The vault-init bundle stays in 05-pki-secrets with same dependencies.
Read `deploy-fleet-helmops.sh` lines 96-120 to confirm.

- [ ] **Step 2: Bump BUNDLE_VERSION in .env**

```bash
# In .env, increment:
BUNDLE_VERSION=1.0.52
```

- [ ] **Step 3: Test full deploy cycle**

```bash
cd /home/rocky/data/harvester-rke2-svcs/fleet-gitops
bash scripts/deploy.sh --delete
bash scripts/deploy.sh
```

Verify:
- vault-init Job completes successfully
- Pre-created policies exist: `vault policy list | grep eso-`
- Bootstrap roles exist: `vault list auth/kubernetes/role | grep bootstrap-`
- ClusterSecretStore is Ready: `kubectl get clustersecretstore vault-bootstrap`
- Admin creds seeded: `vault kv get kv/admin/keycloak`, `vault kv get kv/admin/minio`
- All existing services still deploy correctly

- [ ] **Step 4: Commit test results**

```bash
git commit -m "test: validate Phase 1 vault-init minimal deployment"
```

---

## Chunk 2: Phase 2 — Shared Init Library

### Task 2.1: Create init-lib.sh ConfigMap

**Files:**
- Create: `fleet-gitops/05-pki-secrets/vault-init/manifests/configmap-init-lib.yaml`

This ConfigMap contains reusable shell functions that all per-service init
Jobs will source. Deployed in the `vault` namespace, referenced by Jobs via
cross-namespace ConfigMap or embedded in each bundle.

- [ ] **Step 1: Create init-lib.sh with Vault functions**

```bash
#!/usr/bin/env bash
# init-lib.sh — Shared functions for per-service init Jobs
# Sourced by each <service>-init Job
set -euo pipefail

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
  echo "[INFO] Authenticated to Vault as role: ${role}" >&2
}

#######################################################################
# Vault KV — get or generate secrets
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
  local generated
  generated=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "${length}")
  echo "${generated}"
}

vault_kv_put() {
  local path="$1"
  shift
  vault kv put "kv/${path}" "$@"
  echo "[INFO] Written to kv/${path}" >&2
}

#######################################################################
# Vault Policy — bind pre-created policies to auth roles
#######################################################################
vault_bind_eso_roles() {
  local namespace="$1"
  local sa_name="${2:-external-secrets}"

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

  echo "[INFO] Bound ESO roles for namespace: ${namespace}" >&2
}

#######################################################################
# Keycloak OIDC Client — upsert via REST API
#######################################################################
keycloak_create_oidc_client() {
  local client_id="$1"
  local redirect_uri="$2"
  local pkce="${3:-S256}"  # S256 or disabled
  local keycloak_url="${KEYCLOAK_URL}"
  local admin_pass
  admin_pass=$(cat /secrets/keycloak-admin-password 2>/dev/null || echo "${KEYCLOAK_ADMIN_PASS:-}")

  # Get admin token
  local token
  token=$(curl -s --http1.1 -X POST \
    "${keycloak_url}/realms/master/protocol/openid-connect/token" \
    -d "grant_type=client_credentials&client_id=admin-cli" \
    -d "username=admin&password=${admin_pass}&grant_type=password" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")

  local realm="platform"
  local api="${keycloak_url}/admin/realms/${realm}/clients"

  # Check if client exists
  local existing_id
  existing_id=$(curl -s --http1.1 -H "Authorization: Bearer ${token}" \
    "${api}?clientId=${client_id}" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null || true)

  # Generate client secret
  local client_secret
  client_secret=$(vault_get_or_generate "oidc/${client_id}" "client-secret")

  local cookie_secret
  cookie_secret=$(vault_get_or_generate "oidc/${client_id}" "cookie-secret" 16)

  # Build client JSON
  local pkce_attrs=""
  if [[ "${pkce}" == "S256" ]]; then
    pkce_attrs='"pkce.code.challenge.method": "S256"'
  fi

  local client_json
  client_json=$(cat <<CLIENTEOF
{
  "clientId": "${client_id}",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": false,
  "secret": "${client_secret}",
  "redirectUris": ["${redirect_uri}"],
  "webOrigins": ["+"],
  "standardFlowEnabled": true,
  "directAccessGrantsEnabled": false,
  "attributes": {
    "post.logout.redirect.uris": "${redirect_uri%/*}/*"${pkce_attrs:+, ${pkce_attrs}}
  }
}
CLIENTEOF
  )

  if [[ -n "${existing_id}" ]]; then
    # Update existing client
    curl -s --http1.1 -X PUT -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      "${api}/${existing_id}" -d "${client_json}" >/dev/null
    echo "[INFO] Updated OIDC client: ${client_id}" >&2
  else
    # Create new client
    curl -s --http1.1 -X POST -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      "${api}" -d "${client_json}" >/dev/null
    echo "[INFO] Created OIDC client: ${client_id}" >&2
  fi

  # Store in Vault
  vault_kv_put "oidc/${client_id}" \
    client-secret="${client_secret}" \
    cookie-secret="${cookie_secret}"
}

#######################################################################
# MinIO Bucket + Access Key — upsert via mc CLI
#######################################################################
minio_create_bucket() {
  local bucket="$1"
  local minio_url="${MINIO_ENDPOINT}"
  local root_user
  local root_pass
  root_user=$(cat /secrets/minio-root-user 2>/dev/null || echo "${MINIO_ROOT_USER:-}")
  root_pass=$(cat /secrets/minio-root-password 2>/dev/null || echo "${MINIO_ROOT_PASSWORD:-}")

  mc alias set myminio "${minio_url}" "${root_user}" "${root_pass}" --api S3v4
  mc mb --ignore-existing "myminio/${bucket}"
  echo "[INFO] Ensured bucket exists: ${bucket}" >&2
}

minio_create_access_key() {
  local sa_name="$1"
  local bucket_policy="$2"  # comma-separated bucket names
  local vault_path="$3"

  local access_key secret_key

  # Check if key already exists in Vault
  access_key=$(vault kv get -field=access-key "kv/${vault_path}" 2>/dev/null || true)
  secret_key=$(vault kv get -field=secret-key "kv/${vault_path}" 2>/dev/null || true)

  if [[ -n "${access_key}" && -n "${secret_key}" ]]; then
    echo "[INFO] MinIO access key already exists for: ${sa_name}" >&2
    return 0
  fi

  # Create new service account
  local creds
  creds=$(mc admin user svcacct add myminio minio-admin --json 2>/dev/null || true)
  access_key=$(echo "${creds}" | python3 -c "import json,sys; print(json.load(sys.stdin)['accessKey'])")
  secret_key=$(echo "${creds}" | python3 -c "import json,sys; print(json.load(sys.stdin)['secretKey'])")

  # Store in Vault
  vault_kv_put "${vault_path}" \
    access-key="${access_key}" \
    secret-key="${secret_key}"

  echo "[INFO] Created MinIO access key: ${sa_name}" >&2
}
```

- [ ] **Step 2: Wrap in ConfigMap YAML**

Create `configmap-init-lib.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: init-lib
  namespace: vault
data:
  init-lib.sh: |
    <contents of init-lib.sh above>
```

- [ ] **Step 3: Commit**

```bash
git add fleet-gitops/05-pki-secrets/vault-init/manifests/configmap-init-lib.yaml
git commit -m "feat: add shared init-lib.sh ConfigMap for per-service init Jobs"
```

---

## Chunk 3: Phase 3 — Keycloak Realm Init

### Task 3.1: Create keycloak-realm-init Job

**Files:**
- Create: `fleet-gitops/10-identity/keycloak-realm-init/fleet.yaml`
- Create: `fleet-gitops/10-identity/keycloak-realm-init/manifests/realm-init-job.yaml`
- Modify: `fleet-gitops/10-identity/keycloak-config/manifests/keycloak-config-job.yaml`

The existing `keycloak-config` Job creates all 14 OIDC clients. Split into:
- `keycloak-realm-init` — realm + 5 infra clients (Vault, Rancher, Traefik, Hubble, Keycloak)
- Remaining 9 clients move to per-service init Jobs in Phases 5-8

- [ ] **Step 1: Create fleet.yaml for keycloak-realm-init**

```yaml
defaultNamespace: keycloak
helm: {}
```

- [ ] **Step 2: Create realm-init-job.yaml**

Extract realm creation + 5 infra client creation from existing
`keycloak-config-job.yaml`. The Job authenticates to Vault via K8s auth
(NOT root token), reads Keycloak admin creds from `/secrets/`, creates:

1. Platform realm with SSO config
2. Vault OIDC client + Vault OIDC auth roles
3. Rancher OIDC client
4. Traefik OIDC client (for oauth2-proxy)
5. Hubble OIDC client (for oauth2-proxy)
6. Keycloak admin realm config

Use init-lib.sh functions: `vault_k8s_login`, `keycloak_create_oidc_client`,
`vault_kv_put`.

Key: Mount init-lib ConfigMap from vault namespace as a volume.

- [ ] **Step 3: Strip keycloak-config down to realm-init**

Remove the 9 per-service OIDC client creation blocks from keycloak-config.
Keep realm creation + 5 infra clients. Rename to keycloak-realm-init.

- [ ] **Step 4: Replace root token auth with K8s auth**

Replace:
```bash
init_json=$(kubectl get secret vault-init-keys -n vault ...)
ROOT_TOKEN=$(echo "$init_json" | ...)
```

With:
```bash
source /init-lib/init-lib.sh
vault_k8s_login "bootstrap-keycloak-keycloak"
```

- [ ] **Step 5: Update push-bundles.sh**

Add entry:
```bash
"10-identity/keycloak-realm-init:identity-keycloak-realm-init"
```

- [ ] **Step 6: Update deploy-fleet-helmops.sh**

Replace:
```
"identity-keycloak-config|...|identity-keycloak-config|identity-keycloak|"
```
With:
```
"identity-keycloak-realm-init|...|identity-keycloak-realm-init|identity-keycloak|"
```

Update all downstream `dependsOn` references from `identity-keycloak-config`
to `identity-keycloak-realm-init`.

- [ ] **Step 7: Test deploy cycle**

```bash
BUNDLE_VERSION=1.0.53  # bump
bash scripts/deploy.sh --delete && bash scripts/deploy.sh
```

Verify: realm exists, 5 OIDC clients created, Vault OIDC auth works,
Traefik/Hubble/Vault oauth2-proxy still functional.

- [ ] **Step 8: Commit**

```bash
git add fleet-gitops/10-identity/keycloak-realm-init/
git add fleet-gitops/10-identity/keycloak-config/
git add fleet-gitops/scripts/push-bundles.sh
git add fleet-gitops/scripts/deploy-fleet-helmops.sh
git commit -m "refactor: extract keycloak-realm-init from keycloak-config (5 infra clients)"
```

---

## Chunk 4: Phase 4 — 11-Infra-Auth Bundle

### Task 4.1: Create 11-infra-auth Bundle Structure

**Files:**
- Create: `fleet-gitops/11-infra-auth/` directory tree
- Move from: `fleet-gitops/20-monitoring/ingress-auth/manifests/` (7 files)
- Modify: `fleet-gitops/scripts/push-bundles.sh`
- Modify: `fleet-gitops/scripts/deploy-fleet-helmops.sh`

- [ ] **Step 1: Create directory structure**

```
11-infra-auth/
  traefik-auth/
    fleet.yaml
    manifests/
      (moved from 20-monitoring/ingress-auth: traefik-oauth2-proxy.yaml,
       traefik-external-secret.yaml)
  vault-auth/
    fleet.yaml
    manifests/
      (moved: vault-gateway.yaml, vault-httproute.yaml, vault-external-secret.yaml)
  hubble-auth/
    fleet.yaml
    manifests/
      (moved: hubble-gateway.yaml, hubble-httproute.yaml,
       hubble-oauth2-proxy deployment if exists)
```

- [ ] **Step 2: Move files from 20-monitoring/ingress-auth**

Move (not copy) the 7 files identified in the explore audit:
- `traefik-oauth2-proxy.yaml` → `11-infra-auth/traefik-auth/manifests/`
- `traefik-external-secret.yaml` → `11-infra-auth/traefik-auth/manifests/`
- `vault-gateway.yaml` → `11-infra-auth/vault-auth/manifests/`
- `vault-httproute.yaml` → `11-infra-auth/vault-auth/manifests/`
- `vault-external-secret.yaml` → `11-infra-auth/vault-auth/manifests/`
- `hubble-gateway.yaml` → `11-infra-auth/hubble-auth/manifests/`
- `hubble-httproute.yaml` → `11-infra-auth/hubble-auth/manifests/`

- [ ] **Step 3: Create fleet.yaml files**

Each sub-bundle needs a `fleet.yaml` with `defaultNamespace` set to the
existing namespace (kube-system for Traefik, vault for Vault, monitoring for
Hubble).

- [ ] **Step 4: Update push-bundles.sh**

Add entries:
```bash
"11-infra-auth/traefik-auth:infra-auth-traefik"
"11-infra-auth/vault-auth:infra-auth-vault"
"11-infra-auth/hubble-auth:infra-auth-hubble"
```

- [ ] **Step 5: Update deploy-fleet-helmops.sh**

Add HelmOp definitions after identity block:
```bash
"infra-auth-traefik|oci://${HARBOR}/fleet/infra-auth-traefik|${BUNDLE_VERSION}|kube-system|infra-auth-traefik|identity-keycloak-realm-init|"
"infra-auth-vault|oci://${HARBOR}/fleet/infra-auth-vault|${BUNDLE_VERSION}|vault|infra-auth-vault|identity-keycloak-realm-init|"
"infra-auth-hubble|oci://${HARBOR}/fleet/infra-auth-hubble|${BUNDLE_VERSION}|monitoring|infra-auth-hubble|identity-keycloak-realm-init|"
```

Update `monitoring-ingress-auth` to no longer depend on infra services it
no longer manages.

- [ ] **Step 6: Test deploy cycle**

```bash
BUNDLE_VERSION=1.0.54
bash scripts/deploy.sh --delete && bash scripts/deploy.sh
```

Verify: Traefik dashboard, Hubble UI, and Vault UI are all accessible
with OIDC auth. Monitoring stack deploys without the moved files.

- [ ] **Step 7: Commit**

```bash
git add fleet-gitops/11-infra-auth/
git add fleet-gitops/20-monitoring/ingress-auth/
git add fleet-gitops/scripts/push-bundles.sh
git add fleet-gitops/scripts/deploy-fleet-helmops.sh
git commit -m "feat: add 11-infra-auth bundle, extract from monitoring-ingress-auth"
```

---

## Chunk 5: Phase 5 — Per-Service Init Jobs (Identity + Monitoring)

### Task 5.1: Create keycloak-init Job

**Files:**
- Create: `fleet-gitops/10-identity/keycloak-init/fleet.yaml`
- Create: `fleet-gitops/10-identity/keycloak-init/manifests/keycloak-init-job.yaml`
- Create: `fleet-gitops/10-identity/keycloak-init/manifests/bootstrap-external-secret.yaml`
- Create: `fleet-gitops/10-identity/keycloak-init/manifests/serviceaccount.yaml`

The keycloak-init Job:
1. Authenticates to Vault via K8s auth (bootstrap-keycloak-keycloak)
2. Binds eso-reader-keycloak and eso-writer-keycloak policies
3. Creates namespace-scoped SecretStore
4. Generates Keycloak admin password (vault_get_or_generate)
5. Generates keycloak-pg DB password
6. Writes all to kv/services/keycloak/*

- [ ] **Step 1: Create bootstrap ExternalSecret**

Uses ClusterSecretStore `vault-bootstrap` to read admin creds:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: keycloak-bootstrap-admin
  namespace: keycloak
spec:
  refreshInterval: "0"
  secretStoreRef:
    name: vault-bootstrap
    kind: ClusterSecretStore
  target:
    name: keycloak-bootstrap-admin
    creationPolicy: Owner
  data:
    - secretKey: keycloak-admin-password
      remoteRef:
        key: admin/keycloak
        property: admin-password
```

- [ ] **Step 2: Create keycloak-init Job**

Follow init Job template from design doc. Sources init-lib.sh.
Steps: vault_k8s_login → vault_bind_eso_roles → vault_get_or_generate
for admin password and DB password → vault_kv_put.

- [ ] **Step 3: Update deploy-fleet-helmops.sh**

Add `identity-keycloak-init` HelmOp before `identity-cnpg-keycloak`:
```
"identity-keycloak-init|...|identity-keycloak-init|pki-external-secrets|"
```

Update `identity-cnpg-keycloak` to depend on `identity-keycloak-init`:
```
"identity-cnpg-keycloak|...|identity-cnpg-keycloak|identity-keycloak-init,operators-cnpg|"
```

- [ ] **Step 4: Commit**

### Task 5.2: Create grafana-init Job

Same pattern as keycloak-init but for Grafana:
1. Vault policy + ESO roles
2. OIDC client (grafana)
3. DB password (grafana-pg)
4. Admin password

**Files:**
- Create: `fleet-gitops/20-monitoring/grafana-init/fleet.yaml`
- Create: `fleet-gitops/20-monitoring/grafana-init/manifests/grafana-init-job.yaml`
- Create: `fleet-gitops/20-monitoring/grafana-init/manifests/bootstrap-external-secret.yaml`
- Create: `fleet-gitops/20-monitoring/grafana-init/manifests/serviceaccount.yaml`

### Task 5.3: Create prometheus-init Job

Simpler — only Vault policy + OIDC client (oauth2-proxy). No DB, no MinIO.

### Task 5.4: Create alertmanager-init Job

Same as prometheus-init — Vault policy + OIDC client only.

### Task 5.5: Create loki-init and alloy-init Jobs

Simplest — Vault policy only. No OIDC, no DB, no MinIO (future).

### Task 5.6: Remove monitoring-secrets bundle

Delete `fleet-gitops/20-monitoring/monitoring-secrets/` — replaced by
per-service init Jobs above.

Update deploy-fleet-helmops.sh to remove `monitoring-secrets` HelmOp
and replace dependencies.

### Task 5.7: Test full deploy cycle

```bash
BUNDLE_VERSION=1.0.55
bash scripts/deploy.sh --delete && bash scripts/deploy.sh
```

---

## Chunk 6: Phase 6 — Per-Service Init Jobs (Harbor)

### Task 6.1: Create harbor-init Job

The most complex init Job — handles ALL Harbor external deps:
1. Vault policy + ESO roles
2. Keycloak OIDC client (harbor)
3. MinIO bucket (harbor) + access key (harbor-sa)
4. Valkey password
5. Harbor admin password
6. DB password (harbor-pg)
7. S3 credentials

**Files:**
- Create: `fleet-gitops/30-harbor/harbor-init/fleet.yaml`
- Create: `fleet-gitops/30-harbor/harbor-init/manifests/harbor-init-job.yaml`
- Create: `fleet-gitops/30-harbor/harbor-init/manifests/bootstrap-external-secret.yaml`
- Create: `fleet-gitops/30-harbor/harbor-init/manifests/serviceaccount.yaml`

### Task 6.2: Remove harbor-credentials bundle

Delete `fleet-gitops/30-harbor/harbor-credentials/` — replaced by harbor-init.

### Task 6.3: Refactor minio bundle (remove minio-init Job)

Remove `job-create-buckets.yaml` from `fleet-gitops/30-harbor/minio/manifests/`.
MinIO just deploys the server. Bucket creation moves to harbor-init and gitlab-init.

### Task 6.4: Update HELMOP_DEFS

Replace `harbor-credentials` with `harbor-init`. Update dependencies:
```
"harbor-init|...|harbor-init|identity-keycloak-realm-init,pki-external-secrets|"
"harbor-infra|...|harbor-infra|harbor-init,operators-cnpg,operators-redis|"
"harbor-core|...|harbor-core|harbor-infra,minio|"
```

### Task 6.5: Test deploy cycle

---

## Chunk 7: Phase 7 — Per-Service Init Jobs (GitOps)

### Task 7.1: Create argocd-init Job

Vault policy + OIDC client + server secret key.

### Task 7.2: Create rollouts-init and workflows-init Jobs

Vault policy + OIDC client (oauth2-proxy) each.

### Task 7.3: Remove argocd-credentials bundle

Delete `fleet-gitops/40-gitops/argocd-credentials/` — replaced by argocd-init.

### Task 7.4: Simplify argocd-gitlab-setup

Now only creates: platform-deployments repo + ApplicationSet CR.
No per-repo credential setup.

### Task 7.5: Test deploy cycle

---

## Chunk 8: Phase 8 — Per-Service Init Jobs (GitLab)

### Task 8.1: Create gitlab-init Job

Most complex after harbor:
1. Vault policy + ESO roles
2. Keycloak OIDC client (gitlab, PKCE disabled)
3. MinIO: 9 buckets + gitlab-sa access key
4. Redis password (gitlab-redis)
5. DB passwords (gitlab-pg + praefect)
6. Runner registration token
7. Registry credentials

### Task 8.2: Remove gitlab-credentials bundle

Delete `fleet-gitops/50-gitlab/gitlab-credentials/` — replaced by gitlab-init.

### Task 8.3: Remove minio dependency on gitlab-credentials

Fix the forward reference: minio no longer depends on gitlab-credentials.
gitlab-init creates its own MinIO bucket.

### Task 8.4: Fix gitlab-redis dependency

Remove circular: gitlab-init depends on pki-external-secrets only, NOT
gitlab-redis.

### Task 8.5: Test full deploy cycle

This is the critical test — all 8 phases together.

```bash
BUNDLE_VERSION=1.0.59
bash scripts/deploy.sh --delete && bash scripts/deploy.sh
```

Verify ALL services: Vault, Keycloak, Prometheus, Grafana, Loki, Alloy,
Harbor, ArgoCD, Argo Rollouts, Argo Workflows, GitLab, GitLab Runners.

---

## Chunk 9: Phase 9 — MinimalCD Developer Experience

### Task 9.1: Create platform-deployments GitLab Repo Structure

This is created by the `argocd-gitlab-setup` Job, not manually.
The Job creates the repo in GitLab with the template structure.

**Files:**
- Modify: `fleet-gitops/40-gitops/argocd-gitlab-setup/manifests/argocd-gitlab-setup-job.yaml`

### Task 9.2: Create Developer Template Directory

The template files (deployment.yaml, rollout.yaml, service.yaml,
gateway.yaml, httproute.yaml, etc.) live in the platform-deployments
repo under `templates/service-template/`.

Created by argocd-gitlab-setup Job as part of initial repo scaffolding.

### Task 9.3: Create ArgoCD AppProject + ApplicationSet

**Files:**
- Create: `fleet-gitops/40-gitops/argocd-manifests/manifests/appproject-developer-apps.yaml`
- Create: `fleet-gitops/40-gitops/argocd-manifests/manifests/applicationset-platform-services.yaml`

Follow the design doc spec for restricted AppProject (`developer-apps`)
and Git Generator ApplicationSet.

### Task 9.4: Create Developer CHECKLIST.md Template

Include the full dependency matrix from the design doc.

### Task 9.5: Test MinimalCD Flow

1. Create a test service directory in platform-deployments
2. Verify ArgoCD auto-discovers and creates Application
3. Verify namespace isolation (cannot deploy to platform namespaces)
4. Verify init Job runs → credentials created → service deploys
5. Clean up test service

### Task 9.6: Final Commit

```bash
git add fleet-gitops/40-gitops/argocd-manifests/manifests/
git add fleet-gitops/40-gitops/argocd-gitlab-setup/
git commit -m "feat: add MinimalCD developer experience with ArgoCD ApplicationSet"
```

---

## Post-Implementation Checklist

- [ ] All 48+ HelmOps deploy successfully via `deploy.sh`
- [ ] No root token usage in any init Job (K8s auth only)
- [ ] ClusterSecretStore is Ready
- [ ] Per-namespace SecretStores are Ready (created by init Jobs)
- [ ] All OIDC clients exist in Keycloak (5 infra + 9 per-service)
- [ ] All MinIO buckets exist (harbor, 9 gitlab, cnpg-backups)
- [ ] All Redis/Valkey instances have passwords in Vault
- [ ] All CNPG databases have credentials in Vault
- [ ] Vault OIDC default role does NOT have admin-policy
- [ ] ArgoCD ApplicationSet auto-discovers test service
- [ ] Developer AppProject restricts to app-* namespaces
- [ ] Init Job TTL is 3600 (1 hour)
- [ ] Init Jobs have securityContext (runAsNonRoot, drop ALL)
- [ ] Documentation updated (getting-started.md, architecture docs)
