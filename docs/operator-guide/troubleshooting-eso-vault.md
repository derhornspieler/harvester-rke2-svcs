# Troubleshooting: ESO + Vault Authentication Failures

**Audience:** Platform Engineers
**Last updated:** 2026-04-04

## Symptoms

- Fleet bundles show `NotReady` with message: `could not get secret data from provider`
- ClusterSecretStore `vault-bootstrap` shows `InvalidProviderConfig`
- ESO logs show: `403 permission denied` on `auth/kubernetes/login`
- Multiple ExternalSecrets across namespaces stop syncing simultaneously

## Root Cause

Vault's Kubernetes auth backend caches the cluster CA certificate and token reviewer JWT. When nodes are disrupted (VM restart, CSI failures, cert rotation), this cache becomes stale. ESO pods also cache their ServiceAccount tokens and don't refresh on auth failure.

## Quick Recovery (< 5 minutes)

### Step 1: Re-run vault-init to reconfigure K8s auth

```bash
cd fleet-gitops/
./scripts/deploy-fleet-helmops.sh --env .env --group 05-pki-secrets
```

Wait for the `vault-init` Job to complete:

```bash
kubectl get jobs -n vault -w
# Wait for: vault-init Complete 1/1
```

### Step 2: Restart ESO to pick up fresh tokens

```bash
kubectl rollout restart deployment/external-secrets -n external-secrets
```

### Step 3: Verify recovery

```bash
# ClusterSecretStore should show Valid/Ready
kubectl get clustersecretstores

# All namespace SecretStores should show Valid
kubectl get secretstores -A

# ExternalSecrets should start syncing
kubectl get externalsecrets -A | grep -v SecretSynced
# Empty output = all synced
```

### Step 4: Verify Fleet bundles

Check Rancher UI → Continuous Delivery → App Bundles. All should return to Active. The only acceptable NotReady is `operators-overprovisioning` (capacity buffer).

## Diagnosis

### Check ESO logs for 403

```bash
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=100 | grep '403'
```

If you see `auth/kubernetes/login Code: 403` — this is the Vault K8s auth issue.

### Check Vault health

```bash
kubectl get pods -n vault
# All 3 vault pods should be Running
# vault-unsealer should be Running

kubectl exec -n vault vault-0 -- vault status
# Should show: Sealed: false
```

### Check SecretStore status per namespace

```bash
kubectl get secretstores -A
# Any showing InvalidProviderConfig need the fix above
```

## Prevention

- **Never restart database VMs** without draining the node first
- **Use `--group` for targeted deploys** — never full deploy unless bootstrapping
- **Monitor** the `VaultBootstrapStoreInvalid` PrometheusRule alert (if configured)

## Architecture Reference

### Vault Auth Flow

```
ESO Pod (namespace: harbor)
  → K8s SA token for "external-secrets" in "harbor"
  → Vault auth/kubernetes/login with role "eso-reader-harbor"
  → Vault validates SA token against K8s API
  → Returns Vault token scoped to policy "eso-reader-harbor"
  → ESO reads kv/services/harbor/*, kv/oidc/harbor
```

### Per-Namespace Isolation

Each namespace has:
- `eso-reader-<ns>` — Vault role for ExternalSecret reads
- `eso-writer-<ns>` — Vault role for PushSecret writes
- `eso-reader-<ns>` policy — scoped to that namespace's KV paths only
- `eso-writer-<ns>` policy — scoped to that namespace's KV paths only
- `external-secrets` ServiceAccount — bound to reader role
- `eso-secrets` ServiceAccount — bound to writer role

### KV Path Structure

```
kv/
├── admin/              — bootstrap admin credentials
│   ├── minio           — MinIO root user/password
│   └── keycloak        — Keycloak admin credentials
├── oidc/               — per-service OIDC client secrets
│   ├── harbor          — Harbor OIDC client ID/secret
│   ├── argocd          — ArgoCD OIDC + server-secretkey
│   ├── grafana         — Grafana OIDC client ID/secret
│   └── ...
├── services/           — per-service operational secrets
│   ├── harbor/         — S3 credentials, admin, valkey password
│   ├── gitlab/         — S3 credentials, license, encryption key
│   ├── database/       — CNPG cluster credentials (per-cluster)
│   │   ├── keycloak-pg
│   │   ├── harbor-pg
│   │   ├── grafana-pg
│   │   └── gitlab-pg
│   ├── minio/          — MinIO root credentials
│   ├── dns/            — ExternalDNS TSIG key
│   └── monitoring/     — Grafana admin, data source credentials
└── ci/                 — CI pipeline secrets
    ├── github-mirror   — GitHub mirror SSH key + API token
    └── fleet-deploy    — Fleet deploy Rancher credentials
```

## Related Issues

- [#32 ESO/Vault K8s auth self-healing](https://gitlab.example.com/infra_and_platform_services/harvester-rke2-svcs/-/issues/32)
- [#27 MinIO S3 auth failure alerting](https://gitlab.example.com/infra_and_platform_services/harvester-rke2-svcs/-/issues/27)
