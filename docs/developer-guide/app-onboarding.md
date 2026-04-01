# App Onboarding Guide

How to onboard a new dev team application to the platform. This process
provisions everything the app needs to authenticate users (Keycloak OIDC),
read secrets (Vault + ESO), and optionally manage its own secrets.

## What App Onboarding Does

For each new app, the onboard Job automatically:

1. Creates a Keycloak OIDC client (confidential, with optional public client for SPAs)
2. Seeds the client secret in Vault at `kv/services/<APP>`
3. Creates an ESO reader Vault policy and Kubernetes auth role for the app namespace
4. Creates the `external-secrets` ServiceAccount in the app namespace
5. Creates a `vault-backend` SecretStore in the app namespace
6. Optionally creates an app-level read/write Vault role for apps that manage their own secrets (e.g. API keys)

After onboarding, the app can create ExternalSecret resources that pull from
`kv/services/<APP>` without any manual Vault configuration.

## How It Works

```
fleet-gitops/60-cicd-onboard/
  fleet.yaml                              # Bundle group definition
  onboard-rbac/                           # Shared ClusterRole + ClusterRoleBinding
    fleet.yaml
    manifests/rbac.yaml
  onboard-<APP>/                          # Per-app onboard bundle
    fleet.yaml
    manifests/onboard-job.yaml            # K8s Job with APP_* env vars
```

Key design decisions:

- **Shared RBAC**: `onboard-rbac/` deploys a `ClusterRole` that allows the
  `harbor-init` ServiceAccount to create SecretStores and ServiceAccounts in
  any namespace. Deployed once, shared by all onboard jobs.
- **Per-app bundle**: Each `onboard-<APP>/` contains a single Job manifest.
  The Job runs in the `harbor` namespace using the `harbor-init` SA with the
  `bootstrap-keycloak-harbor` Vault role.
- **Idempotent**: The Job uses `vault kv get` before generating secrets. If a
  secret already exists in Vault, it is preserved. Keycloak clients are
  updated (PUT) if they already exist, created (POST) if not.
- **Template variables**: Image refs and URLs use `${IMAGE_VAULT}`,
  `${IMAGE_ALPINE_K8S}`, `${VAULT_INTERNAL_URL}`, etc. from `.env`, rendered
  by `render-templates.sh` before pushing.

## APP_* Environment Variables

Every onboard Job has a block of app-specific env vars. These are the only
values you change when onboarding a new app:

| Variable | Description | Example |
|----------|-------------|---------|
| `APP_CLIENT_ID` | Keycloak OIDC client ID | `<APP>` |
| `APP_REDIRECT_URI` | OIDC redirect URI (wildcard OK) | `https://<APP>.dev.<DOMAIN>/*` |
| `APP_WEB_ORIGIN` | Web origin for CORS | `https://<APP>.dev.<DOMAIN>` |
| `APP_NAMESPACE` | Target K8s namespace | `<TEAM>-<APP>` |
| `APP_VAULT_PATH` | Vault KV path (no `kv/` prefix) | `services/<APP>` |
| `APP_PKCE` | PKCE method (`S256` or `disabled`) | `S256` |
| `APP_VAULT_RW` | Enable app-level RW Vault role | `true` or `false` |

## Adding a New App

### 1. Create the bundle directory

```bash
cp -r fleet-gitops/60-cicd-onboard/onboard-identity-portal \
      fleet-gitops/60-cicd-onboard/onboard-<APP>
```

### 2. Update the Job manifest

Edit `onboard-<APP>/manifests/onboard-job.yaml`:

- Change `metadata.name` and labels to `onboard-<APP>`
- Update every `APP_*` env var (see table above)
- If the app does NOT need a public SPA client, remove the Step 3d block
- If the app does NOT need SSH signer access, remove the Step 3c block
- If `APP_VAULT_RW` is `false`, the RW policy/role creation is skipped automatically

### 3. Update fleet.yaml

Edit `onboard-<APP>/fleet.yaml` and set the bundle name:

```yaml
defaultNamespace: harbor
helm:
  releaseName: onboard-<APP>
```

### 4. Register in push-bundles.sh

Add the bundle to the `BUNDLES` array in `scripts/push-bundles.sh`:

```bash
"60-cicd-onboard/onboard-<APP>"
```

### 5. Register in deploy-fleet-helmops.sh

Add the bundle to the `HELMOPS` array, cleanup mappings, and increment the
bundle count in `scripts/deploy-fleet-helmops.sh`.

### 6. Commit, MR, merge, deploy

```bash
# On your feature branch
git add fleet-gitops/60-cicd-onboard/onboard-<APP>/
git commit -m "feat: onboard <APP> to platform"

# After MR merge
vi fleet-gitops/.env          # bump BUNDLE_VERSION
./scripts/push-bundles.sh
./scripts/deploy-fleet-helmops.sh
```

## Deployed Onboard Bundles

| Bundle | APP_CLIENT_ID | APP_NAMESPACE | Features |
|--------|---------------|---------------|----------|
| `onboard-identity-portal` | `identity-portal` | `dev-identity-webui` | OIDC + public client + SSH signer + realm-management roles |
| `onboard-forge` | `forge` | `dev-svc-forge` | OIDC + RW Vault access for API key management |

## Vault Policies

Onboard jobs create up to three Vault policies per app:

### 1. ESO reader -- `eso-reader-<NAMESPACE>`

Created for every onboarded app. Grants read-only access scoped to the app's
Vault path. Bound to `eso-secrets` and `external-secrets` ServiceAccounts.

```hcl
path "kv/data/services/<APP>"    { capabilities = ["read"] }
path "kv/data/services/<APP>/*"  { capabilities = ["read"] }
path "kv/metadata/services/<APP>"   { capabilities = ["read"] }
path "kv/metadata/services/<APP>/*" { capabilities = ["read"] }
```

Kubernetes auth role: `eso-reader-<NAMESPACE>`, bound to SA `eso-secrets` and
`external-secrets` in `<NAMESPACE>`, TTL 1h.

### 2. App read/write -- `app-<CLIENT_ID>`

Created when `APP_VAULT_RW=true`. Grants full CRUD on the app's Vault subtree
so the app can manage its own secrets (API keys, tokens, etc.).

```hcl
path "kv/data/services/<APP>/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "kv/metadata/services/<APP>/*" {
  capabilities = ["read", "list", "delete"]
}
```

Kubernetes auth role: `app-<CLIENT_ID>`, bound to SA `<CLIENT_ID>` and
`default` in `<NAMESPACE>`, TTL 1h.

### 3. SSH signer -- `ssh-signer-<CLIENT_ID>`

Identity-portal specific. Grants access to the Vault SSH client signer engine
for issuing SSH certificates.

```hcl
path "ssh-client-signer/sign/ssh-user" {
  capabilities = ["create", "update"]
}
path "ssh-client-signer/config/ca" {
  capabilities = ["read"]
}
```

This policy is appended to the app role alongside the RW policy.

## Consuming Secrets in Your App

After onboarding, create an `ExternalSecret` in your app namespace:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <APP>-oidc
  namespace: <TEAM>-<APP>
spec:
  refreshInterval: 5m
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: <APP>-oidc
  data:
    - secretKey: client-secret
      remoteRef:
        key: services/<APP>
        property: oidc-client-secret
```

The SecretStore `vault-backend` was created by the onboard job and
authenticates to Vault using the `eso-reader-<NAMESPACE>` role automatically.

## Troubleshooting

**Job fails with "Keycloak auth failed"**: Keycloak is not ready or the
`keycloak-admin-bootstrap` secret is missing in the `harbor` namespace. Check
that bundle group 10-identity deployed successfully.

**SecretStore shows "Forbidden"**: The Vault policy or Kubernetes auth role
was not created. Re-run the onboard job by bumping `BUNDLE_VERSION` and
redeploying. The job is idempotent.

**ExternalSecret stuck on "SecretSyncedError"**: Verify the Vault path matches
`APP_VAULT_PATH`. Paths are relative to `kv/` (e.g. `services/forge`, not
`kv/services/forge`). ESO `refreshInterval` should be `5m` for fast recovery.
