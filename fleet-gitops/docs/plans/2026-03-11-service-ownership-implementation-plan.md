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
and testable via `deploy-fleet-helmops.sh --delete && deploy-fleet-helmops.sh`.
Phases must be implemented in order — each builds on the previous.

| Phase | Name | Scope | Depends On |
|-------|------|-------|------------|
| 1 | Vault-Init Minimal | Shrink vault-init, add ClusterSecretStore, pre-create policies | None |
| 2 | Shared Init Library | init-lib.sh embedded in each bundle (not cross-namespace ConfigMap) | Phase 1 |
| 3 | Keycloak Realm Init | Extract realm + 5 infra clients from keycloak-config + fix Vault OIDC bug | Phase 1 |
| 4 | 11-Infra-Auth Bundle | Extract Traefik/Hubble/Vault oauth2-proxy from monitoring | Phase 3 |
| 5 | Per-Service Init Jobs (Identity + Monitoring) | keycloak-init, grafana-init, prometheus-init, alertmanager-init, loki-init, alloy-init + migrate monitoring-secrets resources | Phase 2, 3 |
| 6 | Per-Service Init Jobs (Harbor) | harbor-init, minio cleanup, harbor-credentials migration | Phase 2, 3 |
| 7 | Per-Service Init Jobs (GitOps) | argocd-init, rollouts-init, workflows-init | Phase 2, 3 |
| 8 | Per-Service Init Jobs (GitLab) | gitlab-init, gitlab-credentials migration, minio dependency fix | Phase 2, 3, 6 |
| 9 | MinimalCD Developer Experience | platform-deployments repo, ApplicationSet, templates | Phase 4, 7 |

**After each phase:** Run `scripts/deploy-fleet-helmops.sh --delete && scripts/deploy-fleet-helmops.sh` to validate.
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

After the existing ESO policy loop, add policy creation for each namespace.
**NOTE:** Use plain string iteration (`for ns in $ESO_NAMESPACES`) to match
existing code pattern — NOT bash array syntax (`${ESO_NAMESPACES[@]}`).

```bash
# Add argocd to namespace list (needed for argocd-init in Phase 7)
ESO_NAMESPACES="database keycloak minio harbor gitlab monitoring gitlab-runners argo-workflows argo-rollouts kube-system external-dns argocd"

# Pre-create template policies for per-service init Jobs
for ns in $ESO_NAMESPACES; do
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

Create bootstrap roles only for namespaces that will have init Jobs.
Not every namespace needs keycloak or minio bootstrap roles.

```bash
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

# Bootstrap roles — only for namespaces with init Jobs
# Namespaces needing base-only bootstrap (Vault + ESO):
BOOTSTRAP_BASE="keycloak monitoring kube-system external-dns argocd argo-workflows argo-rollouts"
for ns in $BOOTSTRAP_BASE; do
  vault write "auth/kubernetes/role/bootstrap-base-${ns}" \
    bound_service_account_names="${ns}-init" \
    bound_service_account_namespaces="${ns}" \
    policies="eso-reader-${ns},eso-writer-${ns}" \
    ttl=1h
done

# Namespaces needing Keycloak admin access (create OIDC clients):
BOOTSTRAP_KEYCLOAK="keycloak monitoring harbor gitlab argocd"
for ns in $BOOTSTRAP_KEYCLOAK; do
  vault write "auth/kubernetes/role/bootstrap-keycloak-${ns}" \
    bound_service_account_names="${ns}-init" \
    bound_service_account_namespaces="${ns}" \
    policies="eso-reader-${ns},eso-writer-${ns},admin-keycloak-reader" \
    ttl=1h
done

# Namespaces needing MinIO admin access (create buckets + access keys):
BOOTSTRAP_MINIO="harbor gitlab"
for ns in $BOOTSTRAP_MINIO; do
  vault write "auth/kubernetes/role/bootstrap-minio-${ns}" \
    bound_service_account_names="${ns}-init" \
    bound_service_account_namespaces="${ns}" \
    policies="eso-reader-${ns},eso-writer-${ns},admin-minio-reader" \
    ttl=1h
done
```

- [ ] **Step 4: Seed admin credentials to Vault KV (idempotent)**

Add at end of vault-init, after existing credential seeding.
**CRITICAL:** Must check-before-write to avoid overwriting existing passwords
on redeploy, which would break running services.

```bash
# Seed Keycloak admin password (idempotent — read first, generate only if missing)
EXISTING_KC_PASS=$(vault kv get -field=admin-password kv/admin/keycloak 2>/dev/null || true)
if [[ -z "${EXISTING_KC_PASS}" ]]; then
  KEYCLOAK_ADMIN_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 32)
  vault kv put kv/admin/keycloak admin-password="${KEYCLOAK_ADMIN_PASS}"
  echo "[INFO] Seeded Keycloak admin password" >&2
else
  echo "[INFO] Keycloak admin password already exists, skipping" >&2
fi

# Seed MinIO root credentials (idempotent)
EXISTING_MINIO_PASS=$(vault kv get -field=root-password kv/admin/minio 2>/dev/null || true)
if [[ -z "${EXISTING_MINIO_PASS}" ]]; then
  MINIO_ROOT_USER="minio-admin"
  MINIO_ROOT_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 32)
  vault kv put kv/admin/minio \
    root-user="${MINIO_ROOT_USER}" \
    root-password="${MINIO_ROOT_PASS}"
  echo "[INFO] Seeded MinIO root credentials" >&2
else
  echo "[INFO] MinIO root credentials already exist, skipping" >&2
fi
```

- [ ] **Step 5: Commit**

```bash
git add fleet-gitops/05-pki-secrets/vault-init/manifests/vault-init-job.yaml
git commit -m "refactor: vault-init pre-create template policies and bootstrap roles"
```

**NOTE:** The Vault OIDC default role security bug fix (removing `admin-policy`
from the `default` role) is deferred to Phase 3, because the OIDC auth
configuration lives in `keycloak-config-job.yaml`, not in vault-init.

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
Read `deploy-fleet-helmops.sh` lines 96-171 (full HELMOP_DEFS array) to confirm.

- [ ] **Step 2: Bump BUNDLE_VERSION in .env**

```bash
# In .env, increment:
BUNDLE_VERSION=1.0.52
```

- [ ] **Step 3: Test full deploy cycle**

```bash
cd /home/rocky/data/harvester-rke2-svcs/fleet-gitops
bash scripts/deploy-fleet-helmops.sh --delete
bash scripts/deploy-fleet-helmops.sh
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

### Task 2.1: Create init-lib.sh

**Files:**
- Create: `fleet-gitops/scripts/init-lib.sh` (canonical source, embedded in each bundle)

**IMPORTANT:** Kubernetes does NOT support cross-namespace ConfigMap volume mounts.
A Job in `keycloak` namespace cannot mount a ConfigMap from `vault` namespace.
Solution: embed `init-lib.sh` as a ConfigMap in each init bundle. The canonical
source lives at `fleet-gitops/scripts/init-lib.sh`. The `render-templates.sh`
script includes it in each bundle's ConfigMap during rendering.

- [ ] **Step 1: Create init-lib.sh with all functions**

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
# Vault KV — get or generate secrets (returns value, does NOT write)
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

  # Generate new random value (caller must vault_kv_put separately)
  tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "${length}"
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

  # Get admin token (password grant only — no duplicate grant_type)
  local token
  token=$(curl -s --http1.1 -X POST \
    "${keycloak_url}/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=admin-cli" \
    -d "username=admin&password=${admin_pass}" \
    | jq -r '.access_token')

  local realm="platform"
  local api="${keycloak_url}/admin/realms/${realm}/clients"

  # Check if client exists
  local existing_id
  existing_id=$(curl -s --http1.1 -H "Authorization: Bearer ${token}" \
    "${api}?clientId=${client_id}" \
    | jq -r '.[0].id // empty' 2>/dev/null || true)

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
    curl -s --http1.1 -X PUT -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      "${api}/${existing_id}" -d "${client_json}" >/dev/null
    echo "[INFO] Updated OIDC client: ${client_id}" >&2
  else
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
# MinIO Bucket + IAM User — upsert via mc CLI
# Uses IAM users with scoped policies (NOT svcacct which inherits root)
#######################################################################
minio_create_bucket() {
  local bucket="$1"
  local minio_url="${MINIO_ENDPOINT}"
  local root_user root_pass
  root_user=$(cat /secrets/minio-root-user 2>/dev/null || echo "${MINIO_ROOT_USER:-}")
  root_pass=$(cat /secrets/minio-root-password 2>/dev/null || echo "${MINIO_ROOT_PASSWORD:-}")

  mc alias set myminio "${minio_url}" "${root_user}" "${root_pass}" --api S3v4
  mc mb --ignore-existing "myminio/${bucket}"
  echo "[INFO] Ensured bucket exists: ${bucket}" >&2
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
    # Verify user exists in MinIO, recreate if not
    if mc admin user info myminio "${access_key}" >/dev/null 2>&1; then
      echo "[INFO] MinIO user already exists for: ${user_name}" >&2
      return 0
    fi
  fi

  # Generate credentials
  access_key=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 20)
  secret_key=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 40)

  # Create IAM user with scoped policy (matches existing minio-init pattern)
  mc admin user add myminio "${access_key}" "${secret_key}"

  # Create scoped IAM policy
  local policy_json
  policy_json=$(cat <<POLICYEOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:*"],
      "Resource": [
        "arn:aws:s3:::${bucket_prefix}",
        "arn:aws:s3:::${bucket_prefix}/*"
      ]
    }
  ]
}
POLICYEOF
  )

  mc admin policy create myminio "${user_name}-policy" /dev/stdin <<< "${policy_json}"
  mc admin policy attach myminio "${user_name}-policy" --user "${access_key}"

  # Store in Vault
  vault_kv_put "${vault_path}" \
    access-key="${access_key}" \
    secret-key="${secret_key}"

  echo "[INFO] Created MinIO IAM user: ${user_name}" >&2
}
```

**NOTE:** Uses `jq` for JSON parsing (available in `IMAGE_ALPINE_K8S`) instead
of `python3` to match existing codebase patterns. Verify `jq` is in the image.

- [ ] **Step 2: Create render step to embed init-lib.sh in each bundle**

Each init bundle will include a ConfigMap manifest:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: init-lib
  namespace: <service-namespace>
data:
  init-lib.sh: |
    <rendered contents of scripts/init-lib.sh>
```

Add a step to `render-templates.sh` that generates this ConfigMap for each
init bundle from the canonical `scripts/init-lib.sh`.

- [ ] **Step 3: Commit**

```bash
git add fleet-gitops/scripts/init-lib.sh
git commit -m "feat: add shared init-lib.sh for per-service init Jobs"
```

---

## Chunk 3: Phase 3 — Keycloak Realm Init

### Task 3.1: Create keycloak-realm-init Job

**Files:**
- Create: `fleet-gitops/10-identity/keycloak-realm-init/fleet.yaml`
- Create: `fleet-gitops/10-identity/keycloak-realm-init/manifests/realm-init-job.yaml`
- Delete: `fleet-gitops/10-identity/keycloak-config/` (replaced entirely)

The existing `keycloak-config` Job creates all 14 OIDC clients. Split into:
- `keycloak-realm-init` — realm + 5 infra clients (Vault, Rancher, Traefik, Hubble, Keycloak)
- Remaining 9 clients move to per-service init Jobs in Phases 5-8

- [ ] **Step 1: Create fleet.yaml for keycloak-realm-init**

```yaml
defaultNamespace: keycloak
helm: {}
```

- [ ] **Step 2: Create realm-init-job.yaml**

Extract from existing `keycloak-config-job.yaml`. The Job:
1. Authenticates to Vault via K8s auth (`vault_k8s_login "bootstrap-keycloak-keycloak"`)
2. Creates platform realm with SSO config (8h idle / 10h max)
3. Creates 5 infra OIDC clients:
   - vault (PKCE disabled — Vault doesn't send PKCE params)
   - rancher (PKCE disabled)
   - traefik (PKCE S256, for oauth2-proxy)
   - hubble (PKCE S256, for oauth2-proxy)
   - keycloak (PKCE S256, account console)
4. Configures Vault OIDC auth (enable, write config, create admin+default roles)
5. Stores all client secrets in Vault

**IMPORTANT:** The Vault OIDC auth configuration currently lives in
`keycloak-config-job.yaml` (lines 376-431, phases 3b-3c). These blocks
must be preserved in `keycloak-realm-init`:
- `vault auth enable oidc` (if not already enabled)
- `vault write auth/oidc/config` (OIDC discovery URL, client ID/secret, CA PEM)
- `vault write auth/oidc/role/admin` (restricted to `platform-admins` group)
- `vault write auth/oidc/role/default` (public access)

- [ ] **Step 3: Fix Vault OIDC default role security bug**

**Moved from Phase 1** — the OIDC auth config lives in keycloak-config, not vault-init.

When writing the `default` OIDC role in the new realm-init-job.yaml:
```bash
# BEFORE (vulnerable — gives all authenticated users admin access):
vault write auth/oidc/role/default \
  policies="default,admin-policy" ...

# AFTER (fixed — default users get default policy only):
vault write auth/oidc/role/default \
  policies="default" ...
```

The `admin` role (restricted to `platform-admins` group) keeps `admin-policy`.

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

**NOTE:** The existing keycloak-config Job has a ClusterRole with `pods/exec`
permission for `vexec` calls (kubectl exec into vault-0). Since we're switching
to Vault HTTP API via K8s auth, remove the ClusterRole entirely — all Vault
calls go through the API, not kubectl exec. This significantly reduces the
Job's RBAC surface.

- [ ] **Step 5: Update push-bundles.sh**

Add entry:
```bash
"10-identity/keycloak-realm-init:identity-keycloak-realm-init"
```

Remove entry:
```bash
"10-identity/keycloak-config:identity-keycloak-config"
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

Also add a new `case` branch for the `--group` filter:
```bash
infra-auth-*) group="11-infra-auth" ;;
```

- [ ] **Step 7: Test deploy cycle**

```bash
BUNDLE_VERSION=1.0.53  # bump
bash scripts/deploy-fleet-helmops.sh --delete && bash scripts/deploy-fleet-helmops.sh
```

Verify: realm exists, 5 OIDC clients created, Vault OIDC auth works
(default role does NOT have admin-policy), Traefik/Hubble/Vault oauth2-proxy
still functional.

- [ ] **Step 8: Commit**

```bash
git add fleet-gitops/10-identity/keycloak-realm-init/
git rm -r fleet-gitops/10-identity/keycloak-config/
git add fleet-gitops/scripts/push-bundles.sh
git add fleet-gitops/scripts/deploy-fleet-helmops.sh
git commit -m "refactor: extract keycloak-realm-init from keycloak-config (5 infra clients)"
```

---

## Chunk 4: Phase 4 — 11-Infra-Auth Bundle

### Task 4.1: Create 11-infra-auth Bundle Structure

**Files:**
- Create: `fleet-gitops/11-infra-auth/` directory tree
- Move from: `fleet-gitops/20-monitoring/ingress-auth/manifests/` (specific files)
- Move from: `fleet-gitops/20-monitoring/monitoring-secrets/manifests/secretstore-kube-system.yaml`
- Modify: `fleet-gitops/scripts/push-bundles.sh`
- Modify: `fleet-gitops/scripts/deploy-fleet-helmops.sh`

- [ ] **Step 1: Audit actual ingress-auth file list**

Read the full contents of `fleet-gitops/20-monitoring/ingress-auth/manifests/`
to identify exactly which files relate to Traefik, Vault, and Hubble infra auth.

Based on audit, the actual files to move are:

**Traefik auth files:**
- `traefik-oauth2-proxy.yaml` → Traefik dashboard oauth2-proxy Deployment
- `traefik-external-secret.yaml` → OIDC creds for Traefik oauth2-proxy
- `traefik-gateway.yaml` → Gateway API Gateway for Traefik dashboard
- `traefik-httproute.yaml` → HTTPRoute for Traefik dashboard
- `traefik-middleware.yaml` → ForwardAuth middleware config

**Vault auth files:**
- `vault-gateway.yaml` → Gateway API Gateway for Vault UI
- `vault-httproute.yaml` → HTTPRoute for Vault UI
(No `vault-external-secret.yaml` exists — Vault UI uses Traefik's oauth2-proxy)

**Hubble auth files:**
- `hubble-gateway.yaml` → Gateway API Gateway for Hubble UI
- `hubble-httproute.yaml` → HTTPRoute for Hubble UI
- `hubble.yaml` → oauth2-proxy Deployment for Hubble
- `external-secret-hubble.yaml` → OIDC creds for Hubble oauth2-proxy
- `middleware-hubble.yaml` → ForwardAuth middleware for Hubble

**SecretStore for kube-system (from monitoring-secrets):**
- `secretstore-kube-system.yaml` → Traefik's ExternalSecret needs this

- [ ] **Step 2: Create directory structure and move files**

```
11-infra-auth/
  traefik-auth/
    fleet.yaml          (defaultNamespace: kube-system)
    manifests/
      traefik-oauth2-proxy.yaml
      traefik-external-secret.yaml
      traefik-gateway.yaml
      traefik-httproute.yaml
      traefik-middleware.yaml
      secretstore-kube-system.yaml  (moved from monitoring-secrets)
  vault-auth/
    fleet.yaml          (defaultNamespace: vault)
    manifests/
      vault-gateway.yaml
      vault-httproute.yaml
  hubble-auth/
    fleet.yaml          (defaultNamespace: monitoring)
    manifests/
      hubble-gateway.yaml
      hubble-httproute.yaml
      hubble.yaml
      external-secret-hubble.yaml
      middleware-hubble.yaml
```

- [ ] **Step 3: Create fleet.yaml files**

Each sub-bundle needs `defaultNamespace` matching where its resources deploy:
- traefik-auth: `kube-system` (Traefik lives there)
- vault-auth: `vault`
- hubble-auth: `monitoring` (Hubble UI/relay in monitoring namespace)

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

Add `--group` filter case branch:
```bash
infra-auth-*) group="11-infra-auth" ;;
```

Update `monitoring-ingress-auth` to no longer manage the moved files.

- [ ] **Step 6: Test deploy cycle**

```bash
BUNDLE_VERSION=1.0.54
bash scripts/deploy-fleet-helmops.sh --delete && bash scripts/deploy-fleet-helmops.sh
```

Verify: Traefik dashboard, Hubble UI, and Vault UI are all accessible
with OIDC auth. Monitoring stack deploys without the moved files.

- [ ] **Step 7: Commit**

```bash
git add fleet-gitops/11-infra-auth/
git add fleet-gitops/20-monitoring/ingress-auth/
git add fleet-gitops/20-monitoring/monitoring-secrets/
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
- Create: `fleet-gitops/10-identity/keycloak-init/manifests/configmap-init-lib.yaml`

The keycloak-init Job:
1. Authenticates to Vault via K8s auth (bootstrap-keycloak-keycloak)
2. Binds eso-reader-keycloak and eso-writer-keycloak policies
3. Creates namespace-scoped SecretStore (reader + writer)
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

Follow init Job template from design doc. Sources init-lib.sh from local
ConfigMap (same namespace). Job security context: `runAsNonRoot: true`,
`drop: [ALL]`, `seccompProfile: RuntimeDefault`. Current implementation uses
`ttlSecondsAfterFinished: 120` (2 minutes); this plan proposed 3600 (1 hour) as a
balance between security and job debugging.

Steps: vault_k8s_login → vault_bind_eso_roles → create SecretStore YAML →
vault_get_or_generate for admin password and DB password → vault_kv_put.

- [ ] **Step 3: Update deploy-fleet-helmops.sh**

Add `identity-keycloak-init` HelmOp before `identity-cnpg-keycloak`:
```
"identity-keycloak-init|oci://${HARBOR}/fleet/identity-keycloak-init|${BUNDLE_VERSION}|keycloak|identity-keycloak-init|pki-external-secrets|"
```

Update `identity-cnpg-keycloak` to depend on `identity-keycloak-init`:
```
"identity-cnpg-keycloak|...|identity-cnpg-keycloak|identity-keycloak-init,operators-cnpg|"
```

- [ ] **Step 4: Commit**

### Task 5.2: Create grafana-init Job

Same pattern as keycloak-init but for Grafana:
1. Vault policy + ESO roles
2. OIDC client (grafana) via `keycloak_create_oidc_client`
3. DB password (grafana-pg)
4. Admin password

**Files:**
- Create: `fleet-gitops/20-monitoring/grafana-init/fleet.yaml`
- Create: `fleet-gitops/20-monitoring/grafana-init/manifests/grafana-init-job.yaml`
- Create: `fleet-gitops/20-monitoring/grafana-init/manifests/bootstrap-external-secret.yaml`
- Create: `fleet-gitops/20-monitoring/grafana-init/manifests/serviceaccount.yaml`
- Create: `fleet-gitops/20-monitoring/grafana-init/manifests/configmap-init-lib.yaml`

**HelmOp:**
```
"monitoring-grafana-init|oci://${HARBOR}/fleet/monitoring-grafana-init|${BUNDLE_VERSION}|monitoring|monitoring-grafana-init|identity-keycloak-realm-init,pki-external-secrets|"
```

Update `monitoring-kube-prometheus-stack` to depend on `monitoring-grafana-init`.

### Task 5.3: Create prometheus-init Job

Simpler — only Vault policy + OIDC client (for oauth2-proxy). No DB, no MinIO.

**Files:**
- Create: `fleet-gitops/20-monitoring/prometheus-init/fleet.yaml`
- Create: `fleet-gitops/20-monitoring/prometheus-init/manifests/prometheus-init-job.yaml`
- Create: `fleet-gitops/20-monitoring/prometheus-init/manifests/bootstrap-external-secret.yaml`
- Create: `fleet-gitops/20-monitoring/prometheus-init/manifests/serviceaccount.yaml`
- Create: `fleet-gitops/20-monitoring/prometheus-init/manifests/configmap-init-lib.yaml`

**HelmOp:**
```
"monitoring-prometheus-init|oci://${HARBOR}/fleet/monitoring-prometheus-init|${BUNDLE_VERSION}|monitoring|monitoring-prometheus-init|identity-keycloak-realm-init,pki-external-secrets|"
```

Update `monitoring-ingress-auth` to depend on `monitoring-prometheus-init`.

### Task 5.4: Create alertmanager-init Job

Same as prometheus-init — Vault policy + OIDC client only.

**Files:**
- Create: `fleet-gitops/20-monitoring/alertmanager-init/fleet.yaml`
- Create: `fleet-gitops/20-monitoring/alertmanager-init/manifests/alertmanager-init-job.yaml`
- Create: `fleet-gitops/20-monitoring/alertmanager-init/manifests/bootstrap-external-secret.yaml`
- Create: `fleet-gitops/20-monitoring/alertmanager-init/manifests/serviceaccount.yaml`
- Create: `fleet-gitops/20-monitoring/alertmanager-init/manifests/configmap-init-lib.yaml`

**HelmOp:**
```
"monitoring-alertmanager-init|oci://${HARBOR}/fleet/monitoring-alertmanager-init|${BUNDLE_VERSION}|monitoring|monitoring-alertmanager-init|identity-keycloak-realm-init,pki-external-secrets|"
```

### Task 5.5: Create loki-init and alloy-init Jobs

Simplest — Vault policy only. No OIDC, no DB, no MinIO (future).

**Files (loki):**
- Create: `fleet-gitops/20-monitoring/loki-init/fleet.yaml`
- Create: `fleet-gitops/20-monitoring/loki-init/manifests/loki-init-job.yaml`
- Create: `fleet-gitops/20-monitoring/loki-init/manifests/serviceaccount.yaml`
- Create: `fleet-gitops/20-monitoring/loki-init/manifests/configmap-init-lib.yaml`

**Files (alloy):**
- Create: `fleet-gitops/20-monitoring/alloy-init/fleet.yaml`
- Create: `fleet-gitops/20-monitoring/alloy-init/manifests/alloy-init-job.yaml`
- Create: `fleet-gitops/20-monitoring/alloy-init/manifests/serviceaccount.yaml`
- Create: `fleet-gitops/20-monitoring/alloy-init/manifests/configmap-init-lib.yaml`

**HelmOps:**
```
"monitoring-loki-init|oci://${HARBOR}/fleet/monitoring-loki-init|${BUNDLE_VERSION}|monitoring|monitoring-loki-init|pki-external-secrets|"
"monitoring-alloy-init|oci://${HARBOR}/fleet/monitoring-alloy-init|${BUNDLE_VERSION}|monitoring|monitoring-alloy-init|pki-external-secrets|"
```

Update `monitoring-loki` to depend on `monitoring-loki-init`.
Update `monitoring-alloy` to depend on `monitoring-alloy-init`.

### Task 5.6: Remove monitoring-secrets bundle + migrate resources

Delete `fleet-gitops/20-monitoring/monitoring-secrets/` — replaced by
per-service init Jobs above.

**Resource migration plan** (from monitoring-secrets/manifests/):
| File | Migration Target |
|------|-----------------|
| `secretstore.yaml` | Each monitoring init Job creates its own SecretStore |
| `secretstore-kube-system.yaml` | Moved to `11-infra-auth/traefik-auth/` in Phase 4 |
| `push-secret.yaml` | Replaced by grafana-init Job (vault_get_or_generate) |
| `external-secret-admin.yaml` | Move to `20-monitoring/kube-prometheus-stack/manifests/` |
| `external-secret-grafana.yaml` | Move to `20-monitoring/kube-prometheus-stack/manifests/` |
| `external-secret-grafana-db.yaml` | Move to `20-monitoring/kube-prometheus-stack/manifests/` |
| `vault-root-ca.yaml` | Move to `20-monitoring/kube-prometheus-stack/manifests/` |
| `additional-scrape-configs.yaml` | Move to `20-monitoring/kube-prometheus-stack/manifests/` |

Update deploy-fleet-helmops.sh to remove `monitoring-secrets` HelmOp
and replace dependencies.

### Task 5.7: Test full deploy cycle

```bash
BUNDLE_VERSION=1.0.55
bash scripts/deploy-fleet-helmops.sh --delete && bash scripts/deploy-fleet-helmops.sh
```

Verify:
- All monitoring-* init Jobs complete
- Per-namespace SecretStores are Ready in monitoring namespace
- Grafana OIDC login works
- Prometheus/Alertmanager oauth2-proxy works
- Grafana admin password in Vault matches running instance
- Grafana DB credentials synced correctly
- Root CA ConfigMap present in monitoring namespace

---

## Chunk 6: Phase 6 — Per-Service Init Jobs (Harbor)

### Task 6.1: Create harbor-init Job

The most complex init Job — handles ALL Harbor external deps:
1. Vault policy + ESO roles
2. Keycloak OIDC client (harbor)
3. MinIO bucket (harbor) + IAM user with scoped policy (harbor-sa)
4. Valkey password
5. Harbor admin password
6. DB password (harbor-pg)
7. S3 credentials (stored at `kv/services/harbor`)

**Files:**
- Create: `fleet-gitops/30-harbor/harbor-init/fleet.yaml`
- Create: `fleet-gitops/30-harbor/harbor-init/manifests/harbor-init-job.yaml`
- Create: `fleet-gitops/30-harbor/harbor-init/manifests/bootstrap-external-secret.yaml`
- Create: `fleet-gitops/30-harbor/harbor-init/manifests/serviceaccount.yaml`
- Create: `fleet-gitops/30-harbor/harbor-init/manifests/configmap-init-lib.yaml`

**IMPORTANT:** harbor-init needs MinIO to be running so it can create
the harbor bucket via `mc`. Add `minio` to dependsOn.

**HelmOp:**
```
"harbor-init|oci://${HARBOR}/fleet/harbor-init|${BUNDLE_VERSION}|harbor|harbor-init|minio,identity-keycloak-realm-init,pki-external-secrets|"
```

### Task 6.2: Remove harbor-credentials bundle + migrate reader ExternalSecrets

Delete `fleet-gitops/30-harbor/harbor-credentials/`.

**Resource migration plan** (from harbor-credentials/manifests/):
| File | Migration Target |
|------|-----------------|
| `secretstore.yaml` | harbor-init Job creates SecretStore |
| `push-secret.yaml` | Replaced by harbor-init Job (vault_get_or_generate) |
| `external-secrets.yaml` | **Move to `30-harbor/harbor/manifests/`** |

**CRITICAL:** The `external-secrets.yaml` contains 3 reader ExternalSecrets
(harbor-admin-credentials, harbor-s3-credentials, harbor-db-credentials)
that the Harbor Helm chart references. These must NOT be deleted — move them
to the harbor-core bundle so they deploy alongside the Helm chart.

### Task 6.3: Refactor minio bundle (remove minio-init Job + cross-namespace ESOs)

Remove from `fleet-gitops/30-harbor/minio/manifests/`:
- `job-create-buckets.yaml` — bucket+user creation moves to harbor-init and gitlab-init
- `external-secret-service-accounts.yaml` — cross-namespace ESOs for GitLab/Harbor SA
  creds are no longer needed (each service's init Job creates its own creds directly)

MinIO bundle now only deploys: server (deployment, service, PVC), root
credentials (push-secret, external-secret, secretstore), and observability
(dashboard ConfigMap, ServiceMonitor, alerts).

**Update minio HelmOp dependencies** — remove credential bundle deps:
```
# BEFORE:
"minio|...|minio|identity-keycloak-config,harbor-credentials,gitlab-credentials|"

# AFTER (no credential deps — just needs ESO):
"minio|...|minio|pki-external-secrets|"
```

### Task 6.4: Update HELMOP_DEFS

```
"harbor-init|oci://${HARBOR}/fleet/harbor-init|${BUNDLE_VERSION}|harbor|harbor-init|minio,identity-keycloak-realm-init,pki-external-secrets|"
"harbor-cnpg|oci://${HARBOR}/fleet/harbor-cnpg|${BUNDLE_VERSION}|database|harbor-cnpg|harbor-init,operators-cnpg|"
"harbor-valkey|oci://${HARBOR}/fleet/harbor-valkey|${BUNDLE_VERSION}|harbor|harbor-valkey|harbor-init,operators-redis|"
"harbor-core|oci://${HARBOR}/fleet/harbor-core|${BUNDLE_VERSION}|harbor|harbor-core|harbor-cnpg,harbor-valkey,minio|"
```

### Task 6.5: Test deploy cycle

```bash
BUNDLE_VERSION=1.0.56
bash scripts/deploy-fleet-helmops.sh --delete && bash scripts/deploy-fleet-helmops.sh
```

Verify:
- harbor-init Job completes
- Harbor bucket exists in MinIO: `mc ls myminio/harbor`
- Harbor IAM user has scoped policy (not root): `mc admin policy entities myminio`
- Harbor admin password in Vault
- harbor-s3-credentials ExternalSecret is synced
- harbor-db-credentials ExternalSecret is synced
- Harbor UI accessible with Keycloak OIDC login
- Image push/pull works

---

## Chunk 7: Phase 7 — Per-Service Init Jobs (GitOps)

### Task 7.1: Create argocd-init Job

Vault policy + OIDC client (PKCE disabled — ArgoCD doesn't send PKCE params)
+ server secret key.

**Files:**
- Create: `fleet-gitops/40-gitops/argocd-init/fleet.yaml`
- Create: `fleet-gitops/40-gitops/argocd-init/manifests/argocd-init-job.yaml`
- Create: `fleet-gitops/40-gitops/argocd-init/manifests/bootstrap-external-secret.yaml`
- Create: `fleet-gitops/40-gitops/argocd-init/manifests/serviceaccount.yaml`
- Create: `fleet-gitops/40-gitops/argocd-init/manifests/configmap-init-lib.yaml`

**HelmOp:**
```
"gitops-argocd-init|oci://${HARBOR}/fleet/gitops-argocd-init|${BUNDLE_VERSION}|argocd|gitops-argocd-init|identity-keycloak-realm-init,pki-external-secrets|"
```

Update `gitops-argocd` to depend on `gitops-argocd-init`.

### Task 7.2: Create rollouts-init and workflows-init Jobs

Vault policy + OIDC client (oauth2-proxy, PKCE S256) each.

**Files (rollouts):**
- Create: `fleet-gitops/40-gitops/rollouts-init/fleet.yaml`
- Create: `fleet-gitops/40-gitops/rollouts-init/manifests/rollouts-init-job.yaml`
- Create: `fleet-gitops/40-gitops/rollouts-init/manifests/serviceaccount.yaml`
- Create: `fleet-gitops/40-gitops/rollouts-init/manifests/configmap-init-lib.yaml`

**Files (workflows):**
- Create: `fleet-gitops/40-gitops/workflows-init/fleet.yaml`
- Create: `fleet-gitops/40-gitops/workflows-init/manifests/workflows-init-job.yaml`
- Create: `fleet-gitops/40-gitops/workflows-init/manifests/serviceaccount.yaml`
- Create: `fleet-gitops/40-gitops/workflows-init/manifests/configmap-init-lib.yaml`

**HelmOps:**
```
"gitops-rollouts-init|oci://${HARBOR}/fleet/gitops-rollouts-init|${BUNDLE_VERSION}|argo-rollouts|gitops-rollouts-init|pki-external-secrets|"
"gitops-workflows-init|oci://${HARBOR}/fleet/gitops-workflows-init|${BUNDLE_VERSION}|argo-workflows|gitops-workflows-init|pki-external-secrets|"
```

### Task 7.3: Remove argocd-credentials bundle

Delete `fleet-gitops/40-gitops/argocd-credentials/` — replaced by argocd-init.

**Migrate reader ExternalSecrets** from `argocd-credentials/manifests/` to
`40-gitops/argocd-manifests/manifests/` (if any exist for ArgoCD OIDC config).

### Task 7.4: Simplify argocd-gitlab-setup

Now only creates: platform-deployments repo + ApplicationSet CR.
No per-repo credential setup.

### Task 7.5: Test deploy cycle

```bash
BUNDLE_VERSION=1.0.57
bash scripts/deploy-fleet-helmops.sh --delete && bash scripts/deploy-fleet-helmops.sh
```

Verify:
- All gitops-*-init Jobs complete
- ArgoCD OIDC login works
- Argo Rollouts dashboard accessible
- Argo Workflows UI accessible

---

## Chunk 8: Phase 8 — Per-Service Init Jobs (GitLab)

### Task 8.1: Create gitlab-init Job

Most complex after harbor:
1. Vault policy + ESO roles
2. Keycloak OIDC client (gitlab, PKCE disabled — GitLab doesn't send PKCE)
3. MinIO: 9 buckets (gitlab-lfs, gitlab-artifacts, gitlab-uploads, gitlab-packages,
   gitlab-pages, gitlab-mr-diffs, gitlab-terraform, gitlab-ci-secure-files,
   gitlab-dependency-proxy) + gitlab-sa IAM user with `gitlab-*` bucket prefix policy
4. Redis password (gitlab-redis)
5. DB passwords (gitlab-pg + praefect: gitaly-secret, praefect-secret, praefect-dbsecret)
6. Runner registration token
7. GitLab MinIO storage credentials (accesskey + secretkey at `kv/services/gitlab/minio-storage`)

**Files:**
- Create: `fleet-gitops/50-gitlab/gitlab-init/fleet.yaml`
- Create: `fleet-gitops/50-gitlab/gitlab-init/manifests/gitlab-init-job.yaml`
- Create: `fleet-gitops/50-gitlab/gitlab-init/manifests/bootstrap-external-secret.yaml`
- Create: `fleet-gitops/50-gitlab/gitlab-init/manifests/serviceaccount.yaml`
- Create: `fleet-gitops/50-gitlab/gitlab-init/manifests/configmap-init-lib.yaml`

**NOTE:** GitLab Helm chart requires a SINGLE S3 credential for all 9 bucket
types — cannot use per-bucket access keys. The IAM user policy uses
`arn:aws:s3:::gitlab-*` prefix to scope access.

**HelmOp:**
```
"gitlab-init|oci://${HARBOR}/fleet/gitlab-init|${BUNDLE_VERSION}|gitlab|gitlab-init|minio,identity-keycloak-realm-init,pki-external-secrets|"
```

### Task 8.2: Remove gitlab-credentials bundle + migrate PushSecrets

Delete `fleet-gitops/50-gitlab/gitlab-credentials/`.

The `push-secret.yaml` generates 4 credentials (gitaly-secret, praefect-secret,
praefect-dbsecret, minio-storage). These are now generated by gitlab-init Job
via `vault_get_or_generate` + `vault_kv_put`.

Verify any reader ExternalSecrets that reference these Vault paths are
preserved in the gitlab-core bundle manifests.

### Task 8.3: Remove minio dependency on gitlab-credentials

Fix the forward reference. The minio bundle currently depends on
`gitlab-credentials` because the old minio-init Job needed GitLab's S3 creds
to create the GitLab service account.

**New minio dependency chain:**
```
# BEFORE:
"minio|...|minio|identity-keycloak-config,harbor-credentials,gitlab-credentials|"

# AFTER:
"minio|...|minio|pki-external-secrets|"
```

This was already updated in Task 6.3, but verify it's applied here since
gitlab-credentials deletion happens in this phase.

### Task 8.4: Fix gitlab-redis dependency

Remove circular: gitlab-init depends on `minio,identity-keycloak-realm-init,pki-external-secrets`
only, NOT `gitlab-redis`. The Redis password is generated BY gitlab-init
and consumed by gitlab-redis, so gitlab-redis depends on gitlab-init
(not the reverse).

**New dependency chain:**
```
"gitlab-init|...|gitlab-init|minio,identity-keycloak-realm-init,pki-external-secrets|"
"gitlab-redis|...|gitlab-redis|gitlab-init,operators-redis|"
"gitlab-cnpg|...|gitlab-cnpg|gitlab-init,operators-cnpg|"
"gitlab-core|...|gitlab-core|gitlab-redis,gitlab-cnpg,minio|"
```

### Task 8.5: Test full deploy cycle

This is the critical test — all 8 phases together.

```bash
BUNDLE_VERSION=1.0.59
bash scripts/deploy-fleet-helmops.sh --delete && bash scripts/deploy-fleet-helmops.sh
```

Verify ALL services: Vault, Keycloak, Prometheus, Grafana, Loki, Alloy,
Harbor, ArgoCD, Argo Rollouts, Argo Workflows, GitLab, GitLab Runners.

Specific gitlab checks:
- gitlab-init Job completes
- All 9 GitLab buckets exist in MinIO
- GitLab IAM user has `gitlab-*` scoped policy (not root)
- GitLab OIDC login works
- GitLab CI runner registers successfully
- Git push/pull over SSH works (TCPRoute)

---

## Chunk 9: Phase 9 — MinimalCD Developer Experience

### Task 9.1: Create platform-deployments GitLab Repo Structure

This is created by the `argocd-gitlab-setup` Job, not manually.
The Job creates the repo in GitLab with the template structure.

**Files:**
- Modify: `fleet-gitops/40-gitops/argocd-gitlab-setup/manifests/argocd-gitlab-setup-job.yaml`

### Task 9.2: Create Developer Template Directory

The template files (deployment.yaml, rollout.yaml, workflow.yaml, service.yaml,
gateway.yaml, httproute.yaml, etc.) live in the platform-deployments
repo under `templates/service-template/`.

Templates include:
- `deployment.yaml` — standard Kubernetes Deployment
- `rollout.yaml` — Argo Rollout with canary/blue-green strategy
- `workflow.yaml` — Argo Workflow template
- `service.yaml` — ClusterIP Service
- `gateway.yaml` — Gateway API Gateway with cert-manager shim
- `httproute.yaml` — HTTPRoute for the service
- `hpa.yaml` — HorizontalPodAutoscaler (70% CPU target)
- `kustomization.yaml` — Kustomize overlay structure

Created by argocd-gitlab-setup Job as part of initial repo scaffolding.

### Task 9.3: Create ArgoCD AppProject + ApplicationSet

**Files:**
- Create: `fleet-gitops/40-gitops/argocd-manifests/manifests/appproject-developer-apps.yaml`
- Create: `fleet-gitops/40-gitops/argocd-manifests/manifests/applicationset-platform-services.yaml`

Follow the design doc spec for restricted AppProject (`developer-apps`)
and Git Generator ApplicationSet.

### Task 9.4: Verify Argo Rollouts AnalysisTemplates

Check that `fleet-gitops/40-gitops/analysis-templates/` contains the
AnalysisTemplate CRs referenced in the developer template:
- `success-rate-check` — Prometheus success rate query
- `error-rate-check` — Prometheus error rate query
- `latency-p99-check` — Prometheus latency percentile query

If missing, create them in this phase.

### Task 9.5: Create Developer CHECKLIST.md Template

Include the full dependency matrix from the design doc.

### Task 9.6: Test MinimalCD Flow

1. Create a test service directory in platform-deployments
2. Verify ArgoCD auto-discovers and creates Application
3. Verify namespace isolation (cannot deploy to platform namespaces)
4. Verify init Job runs → credentials created → service deploys
5. Test Argo Rollout with canary strategy
6. Test Argo Workflow template execution
7. Clean up test service

### Task 9.7: Final Commit

```bash
git add fleet-gitops/40-gitops/argocd-manifests/manifests/
git add fleet-gitops/40-gitops/argocd-gitlab-setup/
git add fleet-gitops/40-gitops/analysis-templates/
git commit -m "feat: add MinimalCD developer experience with ArgoCD ApplicationSet"
```

---

## Post-Implementation Checklist

- [ ] All 48+ HelmOps deploy successfully via `deploy-fleet-helmops.sh`
- [ ] No root token usage in any init Job (K8s auth only)
- [ ] ClusterSecretStore `vault-bootstrap` is Ready
- [ ] Per-namespace SecretStores are Ready (created by init Jobs)
- [ ] All OIDC clients exist in Keycloak (5 infra + 9 per-service)
- [ ] All MinIO buckets exist (harbor, 9 gitlab, cnpg-backups)
- [ ] All MinIO IAM users have scoped policies (not root-level svcacct)
- [ ] Harbor Valkey credentials in `kv/services/harbor/valkey-password`
- [ ] GitLab Redis credentials in `kv/services/gitlab/redis-password`
- [ ] All CNPG databases have credentials in Vault
- [ ] Vault OIDC default role does NOT have admin-policy
- [ ] ArgoCD ApplicationSet auto-discovers test service
- [ ] Developer AppProject restricts to app-* namespaces
- [ ] Init Job TTL is 120 (2 minutes) — current implementation; this plan proposed 3600 as alternative
- [ ] Init Jobs have securityContext (runAsNonRoot, drop ALL, seccompProfile RuntimeDefault)
- [ ] No cross-namespace ConfigMap mounts (init-lib.sh embedded per bundle)
- [ ] monitoring-secrets resources fully migrated (vault-root-ca, scrape-configs, reader ESOs)
- [ ] harbor-credentials reader ExternalSecrets migrated to harbor-core
- [ ] minio bundle has no credential bundle dependencies
- [ ] Documentation updated (getting-started.md, architecture docs)
- [ ] Argo Rollouts AnalysisTemplates exist for developer template references
