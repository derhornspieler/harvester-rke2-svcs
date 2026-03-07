# Deployment Issues Postmortem — 2026-03-07

## Summary

Full teardown (6→1) and redeploy (1→6) exposed 6 issues, 2 user-requested improvements, and several airgap/CRD gotchas. All have been fixed in code. This document describes what happened, why, and what was changed.

---

## Issue 1: PKI Certificate Chain `notBefore` Timing

### What Happened
After generating a fresh root CA and running `deploy-pki-secrets.sh`, the vault-tls certificate issued by cert-manager failed chain validation. The error indicated the intermediate CA's `notBefore` date preceded the root CA's `notBefore`.

### Root Cause
`openssl x509 -req` defaults `notBefore` to "now". If the root CA was generated seconds before signing the intermediate CSR, clock skew or sub-second differences meant the intermediate's `notBefore` could precede the root's. This violates X.509 chain constraints — a child certificate cannot be valid before its parent.

### Fix
**File:** `scripts/deploy-pki-secrets.sh` (Phase 3, ~line 242)

- Extract root CA's `notBefore` timestamp
- Set intermediate's `notBefore` to root's `notBefore + 10 seconds`
- Add `openssl verify -CAfile` chain validation after signing — script dies if chain is invalid
- Added before-and-after logging so the timestamps are visible

### How To Avoid Going Forward
The script now enforces correct ordering and validates the chain. A freshly generated root CA will always produce a valid intermediate. Re-running Phase 3 regenerates the intermediate.

---

## Issue 2: CNPG CRDs Not Installed

### What Happened
The CNPG operator Helm install failed because the CRDs were not present on the cluster. Helm's built-in CRD install can fail with "annotation too long" errors on large CRDs. Manual install with `kubectl apply --server-side --force-conflicts` was required.

### Root Cause
CNPG CRDs are 18,000+ lines. Standard `kubectl apply` stores the entire manifest in `kubectl.kubernetes.io/last-applied-configuration` annotation, exceeding the 256KB metadata limit. `--server-side` uses server-side apply which avoids this annotation.

### Fix
**Files:**
- `scripts/manifests/cnpg-crds-v0.27.0.yaml` — vendored CRDs extracted from Helm chart v0.27.0
- `scripts/deploy-keycloak.sh` (Phase 1, ~line 117)

Changes:
1. Pre-apply vendored CRDs with `kubectl apply --server-side --force-conflicts` before Helm install
2. Pass `--set crds.create=false` to Helm so it doesn't try to create CRDs itself
3. CRD manifest is version-pinned to the Helm chart version

### Airgap Notes
- CRDs are vendored locally — no internet access needed
- When upgrading the CNPG chart version, re-extract CRDs: `helm template cnpg <chart-dir> --set crds.create=true --show-only templates/crds/crds.yaml > scripts/manifests/cnpg-crds-vX.Y.Z.yaml`
- Update the filename reference in `deploy-keycloak.sh` and `HELM_VERSION_CNPG` in `.env`

---

## Issue 3: Grafana DB Secret / SecretStore Missing in Monitoring

### What Happened
`grafana-db-secret` ExternalSecret in `monitoring` namespace failed with `SecretSyncedError` because no `vault-backend` SecretStore existed in the `monitoring` namespace when `deploy-monitoring.sh` ran.

### Root Cause
The SecretStore for `monitoring` was only created by `setup-keycloak.sh` (Phase 3). If monitoring was deployed before Keycloak setup, or after a keycloak teardown, the SecretStore didn't exist. The ExternalSecret had nothing to pull from.

### Fix
**File:** `scripts/deploy-monitoring.sh` (Phase 2, Grafana PG section)

Added self-contained Vault ESO infrastructure creation:
- For both `monitoring` and `database` namespaces, the script now creates Vault policy, K8s auth role, service account, and SecretStore if they don't already exist
- The policy includes paths for `services/database/*`, `services/<ns>/*`, and `oidc/*`
- Idempotent: skips creation if SecretStore already exists (e.g., from setup-keycloak.sh)

### Dependency Chain
`deploy-monitoring.sh` no longer depends on `setup-keycloak.sh` for the SecretStore. Both scripts create the same resources idempotently. Order no longer matters for this specific dependency.

---

## Issue 4: Traefik LoadBalancer IP Hardcoded

### What Happened
After changing the Cilium L2 announcement pool from `192.168.48.0/24` to `172.29.97.0/24` in Terraform, Traefik's LoadBalancer service still used `192.168.48.2` because it was hardcoded in the HelmChartConfig manifest.

### Root Cause
`services/traefik-dashboard/helmchartconfig.yaml` had `loadBalancerIP: "192.168.48.2"` hardcoded. It was applied with `kubectl apply -f` (no substitution), so changing the Cilium pool had no effect.

### Fix
**Files:**
- `services/traefik-dashboard/helmchartconfig.yaml` — changed to `loadBalancerIP: "CHANGEME_TRAEFIK_LB_IP"`
- `scripts/utils/subst.sh` — added `CHANGEME_TRAEFIK_LB_IP` → `${TRAEFIK_LB_IP:-}` substitution
- `scripts/.env` — added `TRAEFIK_LB_IP="172.29.97.2"`
- `scripts/deploy-traefik-dashboard.sh` — changed `kubectl apply -f` to `kube_apply_subst` for the HelmChartConfig, added `TRAEFIK_LB_IP` validation
- `scripts/deploy-monitoring.sh` — same change for its HelmChartConfig apply

### How To Change LB IP Going Forward
1. Update `TRAEFIK_LB_IP` in `scripts/.env`
2. Update Cilium L2 pool in Terraform
3. Re-run `deploy-traefik-dashboard.sh --phase 1`

---

## Issues 5 & 6: Vault OIDC Secrets Empty

### What Happened
After running `setup-keycloak.sh`, all OIDC client secrets in Vault were empty (0 bytes). ExternalSecrets synced empty secrets, causing OAuth2-proxy pods to fail. Specifically reported: `traefik-oidc` was empty, and all other OAuth2-proxy secrets were also empty.

### Root Cause
The Vault seeding loop in `setup-keycloak.sh` Phase 3 retrieved client secrets from the Keycloak API using `kc_api GET`. When the HTTP/2 connection to Keycloak dropped (1-in-10 chance through Traefik), the function returned empty. The script used `continue` to skip failed clients instead of dying, silently leaving empty secrets in Vault.

The cookie-secret was generated correctly (local `openssl rand`), but the client-secret from Keycloak was empty. Both were written to Vault — resulting in a secret with a valid cookie-secret but empty client-secret.

### Fix
**File:** `scripts/setup-keycloak.sh` (Phase 3, OIDC seeding loop, ~line 409)

1. **Retry on empty secret**: Client secret retrieval now retries 3 times with 2s delay, instead of silently continuing
2. **Die on empty**: If still empty after 3 attempts, the script dies immediately instead of leaving empty secrets
3. **Read-back verification**: After every `vault kv put`, the script reads back the `client-secret` field and verifies it's non-empty. Dies if verification fails.

### Previous Fix (from earlier session)
- `--http1.1` on all curl calls to avoid HTTP/2 multiplexing drops
- Retry logic on `kc_api` and `kc_api_create` functions
- Token cache reduced from 45s to 20s window

---

## Improvement: Helm Chart Versions Centralized in .env

### What Happened (User Feedback)
Helm chart versions were hardcoded in each deploy script, making upgrades tedious — you had to find and update versions across 6+ files.

### Fix
**File:** `scripts/.env`

All Helm chart versions are now centralized:
```bash
HELM_VERSION_CERTMANAGER="v1.19.4"
HELM_VERSION_VAULT="0.32.0"
HELM_VERSION_ESO="2.0.1"
HELM_VERSION_CNPG="0.27.0"
HELM_VERSION_PROMETHEUS_STACK="72.6.2"
HELM_VERSION_HARBOR="1.18.2"
HELM_VERSION_ARGOCD="7.8.8"
HELM_VERSION_ARGO_ROLLOUTS="2.39.1"
HELM_VERSION_ARGO_WORKFLOWS="0.45.1"
HELM_VERSION_GITLAB="9.9.2"
HELM_VERSION_GITLAB_RUNNER="0.86.0"
```

Deploy scripts use `${HELM_VERSION_X:-default}` so they still work without `.env` but prefer the centralized value.

### Upgrade Process
1. Update version in `scripts/.env`
2. If CRDs changed (CNPG, cert-manager), re-vendor the CRD manifests
3. Run the bundle's deploy script

### Why HELM_CHART + HELM_REPO Are Both Needed
`HELM_CHART_*` (e.g., `jetstack/cert-manager`) is the chart reference for `helm install`. `HELM_REPO_*` (e.g., `https://charts.jetstack.io`) is the registry URL for `helm repo add`. Both are required by Helm's architecture. For OCI registries, only the chart path is needed (the `helm_repo_add` function auto-skips `oci://` prefixes). These are per-script defaults, overridable for Harbor pull-through cache or airgap registries.

---

## Airgap & CRD Gotchas Reference

### CRD Installation Pattern
Large CRDs (CNPG, Gateway API) **must** use `kubectl apply --server-side --force-conflicts`:
- Standard apply stores full manifest in annotations → 256KB limit exceeded
- Helm CRD install can also fail for the same reason
- Always vendor CRDs locally and apply before Helm install with `--set crds.create=false`

**Currently vendored CRDs:**
| CRD | File | Used By |
|-----|------|---------|
| Gateway API TCPRoute | `scripts/manifests/gateway.networking.k8s.io_tcproutes.yaml` | cert-manager, Traefik |
| Gateway API TLSRoute | `scripts/manifests/gateway.networking.k8s.io_tlsroutes.yaml` | cert-manager, Traefik |
| CNPG (all) | `scripts/manifests/cnpg-crds-v0.27.0.yaml` | CNPG operator |

### CRD Teardown Gotcha
Helm does not delete CRDs on `helm uninstall`. Orphaned CRDs with stale webhooks block reinstall. Teardown scripts must explicitly delete CRDs:
```bash
kubectl get crd -o name | grep cnpg | xargs -r kubectl delete
kubectl delete validatingwebhookconfiguration cnpg-validating-webhook-configuration
kubectl delete mutatingwebhookconfiguration cnpg-mutating-webhook-configuration
```

### Certificate Chain Requirements
- Root CA `notBefore` must precede intermediate CA `notBefore`
- `update-ca-certificates` requires `.crt` extension AND exactly one certificate per file
- Multi-cert PEM files are silently skipped by `update-ca-certificates`

### Keycloak API Through Traefik
- Use `--http1.1` on all curl calls — HTTP/2 multiplexing causes 1-in-10 connection drops
- Admin token TTL defaults to 60s — increase to 300s via realm settings
- Cache tokens for max 20s to avoid stale tokens on retry

### SecretStore Independence
Every namespace that needs ExternalSecrets must have its own:
1. Vault policy (covering required KV paths)
2. Kubernetes auth role (bound to service account in that namespace)
3. `eso-secrets` service account
4. `vault-backend` SecretStore CR

Deploy scripts should create these idempotently (skip if exists) rather than depending on other bundle scripts to have run first.

### Traefik HelmChartConfig
- Must be reapplied after CP node rolling upgrades (new nodes reset to defaults)
- `loadBalancerIP` must match Cilium L2 pool — now templatized via `TRAEFIK_LB_IP` in `.env`
- Applied via `kube_apply_subst` (not raw `kubectl apply`)

---

## Helm Version Audit (2026-03-07)

### Updated (safe — minor/patch bumps)
| Chart | Old | New | Notes |
|-------|-----|-----|-------|
| CNPG | 0.27.0 | **0.27.1** | Patch, CRDs re-vendored |
| Argo Rollouts | 2.39.1 | **2.40.6** | Minor bump (app v1.8.0 → v1.8.4) |
| Argo Workflows | 0.45.1 | **0.47.4** | Minor bump (app v3.7.1 → v3.7.10) |

### Not Updated (major jumps — need values migration)
| Chart | Current | Latest | Why Not Updated |
|-------|---------|--------|-----------------|
| kube-prometheus-stack | 72.6.2 | 82.10.0 | 10 minor versions — likely breaking changes in CRDs and values schema. Needs dedicated upgrade ticket with staging validation. |
| ArgoCD | 7.8.8 | 9.4.7 | 2 major chart versions — requires values file audit and potential restructuring. ArgoCD app version jumps v2.14 → v3.x. |

### Already Latest
cert-manager v1.19.4, Vault 0.32.0, ESO 2.0.1, Harbor 1.18.2, GitLab 9.9.2, GitLab Runner 0.86.0

### Upgrade Procedure for Major Bumps
1. Create a feature branch
2. `helm show values <chart> --version <new>` → diff against current values file
3. Update values file for renamed/removed keys
4. Test in staging (or single-bundle teardown+redeploy)
5. Update `HELM_VERSION_*` in `.env`
6. If CRDs changed, re-vendor and update `scripts/manifests/`

---

## Files Changed

| File | Change |
|------|--------|
| `scripts/deploy-pki-secrets.sh` | PKI notBefore fix + chain validation + version env vars |
| `scripts/deploy-keycloak.sh` | CNPG CRD pre-install + version env var |
| `scripts/deploy-monitoring.sh` | Self-contained SecretStore creation + version env var + subst for HelmChartConfig |
| `scripts/deploy-traefik-dashboard.sh` | Use kube_apply_subst for HelmChartConfig + TRAEFIK_LB_IP validation |
| `scripts/deploy-harbor.sh` | Version env var |
| `scripts/deploy-argo.sh` | Version env vars |
| `scripts/deploy-gitlab.sh` | Version env vars |
| `scripts/setup-keycloak.sh` | Retry + die on empty secrets + read-back verification |
| `scripts/utils/subst.sh` | Added CHANGEME_TRAEFIK_LB_IP substitution |
| `scripts/.env` | Added TRAEFIK_LB_IP + all Helm chart versions |
| `services/traefik-dashboard/helmchartconfig.yaml` | Templatized loadBalancerIP |
| `scripts/manifests/cnpg-crds-v0.27.0.yaml` | Vendored CNPG CRDs (new file) |
