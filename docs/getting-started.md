# Getting Started

This guide walks through provisioning an RKE2 cluster via Rancher API and
deploying all platform services through Fleet GitOps.

## Prerequisites

### Infrastructure

| Component | Purpose |
|-----------|---------|
| Rancher management cluster | Provisions downstream RKE2 clusters, runs Fleet controller |
| Harbor registry (`harbor.example.com`) | OCI registry for Helm charts and manifest bundles |
| Rancher API token | Bearer token with cluster provisioning and Fleet management permissions |
| Root CA keypair | Offline Root CA for signing the Vault intermediate CA |

### Tools

| Tool | Minimum version | Purpose |
|------|----------------|---------|
| `helm` | 3.14+ | OCI chart push, registry login |
| `kubectl` | 1.28+ | Downstream cluster access (Root CA seeding, Vault CSR signing) |
| `jq` | 1.6+ | JSON processing |
| `python3` + PyYAML | 3.9+ | YAML-to-JSON conversion for HelmOp values |
| `openssl` | 1.1.1+ | Intermediate CSR signing with offline Root CA |
| `curl` | any | Rancher API calls |

Verify all tools are available:

```bash
helm version --short
kubectl version --client
jq --version
python3 -c "import yaml; print('PyYAML OK')"
openssl version
curl --version | head -1
```

### Configuration

Create `fleet-gitops/.env` with the required variables:

```bash
# Rancher API (required)
RANCHER_URL="https://rancher.example.com"
RANCHER_TOKEN="token-xxxxx:yyyyyyyyyyyyyyyyyyyy"

# Harbor OCI registry (required for push-charts.sh / push-bundles.sh)
HARBOR_USER="admin"
HARBOR_PASS="<harbor-password>"

# Bundle version for raw manifest bundles (default: 1.0.0)
BUNDLE_VERSION="1.0.0"
```

Log in to Harbor OCI before pushing:

```bash
helm registry login harbor.example.com
```

---

## Step 1: Provision the RKE2 Cluster

Clusters are provisioned via the Rancher API (not Terraform). The provisioning
script creates an RKE2 cluster on the Harvester infrastructure provider through
the `provisioning.cattle.io/v1` API.

After provisioning, verify the cluster is active in Rancher:

```bash
curl -sk -H "Authorization: Bearer ${RANCHER_TOKEN}" \
  "${RANCHER_URL}/v1/provisioning.cattle.io.clusters/fleet-default/rke2-prod" | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status']['ready'])"
```

The cluster must show `True` before proceeding to deployment.

---

## Step 2: Deploy via Fleet GitOps

The unified deployment script `fleet-gitops/scripts/deploy.sh` runs all phases
in sequence. It can also be run phase-by-phase for debugging or partial
redeployment.

### Full deployment (all phases)

```bash
cd fleet-gitops/scripts
./deploy.sh
```

### Deployment phases

| Phase | Script | What it does |
|-------|--------|--------------|
| 1 | `push-charts.sh` | Pulls upstream Helm charts and pushes them to `oci://harbor.example.com/helm/` |
| 2 | `deploy.sh` (inline) | Seeds Root CA as a TLS Secret on the downstream cluster (`cert-manager/root-ca`), pre-creates namespaces (`cert-manager`, `vault`, `monitoring`, `cluster-autoscaler`), seeds cluster-autoscaler cloud-config |
| 3 | `push-bundles.sh` | Packages raw Kubernetes manifests as OCI artifacts and pushes to `oci://harbor.example.com/fleet/` |
| 4 | `deploy-fleet-helmops.sh` | Creates 37 HelmOp CRs on the Rancher management cluster via the Fleet API. Auto-bootstraps the `harbor-helm-ca` Secret in `fleet-default` namespace |
| 5 | `deploy.sh` (inline) | Waits for `vault-init` Job to generate the intermediate CSR, signs it offline with the Root CA key, imports the signed chain into Vault `pki_int/`, configures the PKI signing role |
| 5.5 | `deploy.sh` (inline) | Seeds service secrets into Vault KV v2 (database credentials, Keycloak admin, Harbor admin, MinIO, Grafana, GitLab). Write-once / idempotent |

Skip the push phases if charts and bundles are already in Harbor:

```bash
./deploy.sh --skip-push
```

### Selective deployment

Deploy a single bundle group:

```bash
./deploy.sh --group 00-operators
```

Dry run (show HelmOp CRs without applying):

```bash
./deploy.sh --dry-run
```

---

## Step 3: Bundle Dependency Ordering

Fleet resolves dependencies via the `dependsOn` field on each HelmOp CR.
Bundles deploy in topological order across seven groups.

### 00-operators (no dependencies)

| HelmOp | Chart / Bundle | Namespace |
|--------|---------------|-----------|
| `operators-cnpg` | `cloudnative-pg` 0.27.1 | `cnpg-system` |
| `operators-redis` | `redis-operator` 0.23.0 | `redis-operator` |
| `operators-node-labeler` | raw bundle | `node-labeler` |
| `operators-storage-autoscaler` | raw bundle | `storage-autoscaler` |
| `operators-cluster-autoscaler` | raw bundle | `cluster-autoscaler` |

### 05-pki-secrets (depends on operators)

| HelmOp | Chart / Bundle | Namespace | Depends on |
|--------|---------------|-----------|------------|
| `pki-cert-manager` | `cert-manager` v1.19.4 | `cert-manager` | `operators-cnpg` |
| `pki-vault` | `vault` 0.32.0 | `vault` | `operators-cnpg` |
| `pki-vault-init` | raw bundle | `vault` | `pki-vault` |
| `pki-vault-unsealer` | raw bundle | `vault` | `pki-vault-init` |
| `pki-vault-pki-issuer` | raw bundle | `cert-manager` | `pki-vault-init`, `pki-cert-manager` |
| `pki-external-secrets` | `external-secrets` 2.0.1 | `external-secrets` | `pki-vault-init` |

### 10-identity (depends on pki)

| HelmOp | Chart / Bundle | Namespace | Depends on |
|--------|---------------|-----------|------------|
| `identity-cnpg-keycloak` | raw bundle | `database` | `pki-external-secrets`, `operators-cnpg` |
| `identity-keycloak` | raw bundle | `keycloak` | `identity-cnpg-keycloak` |
| `identity-keycloak-config` | raw bundle | `keycloak` | `identity-keycloak` |

### 20-monitoring (depends on pki + identity)

| HelmOp | Chart / Bundle | Namespace | Depends on |
|--------|---------------|-----------|------------|
| `monitoring-cnpg-grafana` | raw bundle | `database` | `pki-external-secrets`, `operators-cnpg`, `identity-keycloak-config` |
| `monitoring-secrets` | raw bundle | `monitoring` | `pki-external-secrets`, `identity-keycloak-config` |
| `monitoring-loki` | raw bundle | `monitoring` | `identity-keycloak-config` |
| `monitoring-alloy` | raw bundle | `monitoring` | `identity-keycloak-config` |
| `monitoring-prometheus-stack` | `kube-prometheus-stack` 82.10.0 | `monitoring` | `monitoring-secrets`, `monitoring-cnpg-grafana` |
| `monitoring-ingress-auth` | raw bundle | `monitoring` | `monitoring-prometheus-stack` |

### 30-harbor (depends on pki + identity)

| HelmOp | Chart / Bundle | Namespace | Depends on |
|--------|---------------|-----------|------------|
| `minio` | raw bundle | `minio` | `identity-keycloak-config` |
| `harbor-cnpg` | raw bundle | `database` | `identity-keycloak-config`, `operators-cnpg` |
| `harbor-valkey` | raw bundle | `harbor` | `identity-keycloak-config`, `operators-redis` |
| `harbor-core` | `harbor` 1.18.2 | `harbor` | `minio`, `harbor-cnpg`, `harbor-valkey` |
| `harbor-manifests` | raw bundle | `harbor` | `harbor-core` |

### 40-gitops (depends on pki + identity)

| HelmOp | Chart / Bundle | Namespace | Depends on |
|--------|---------------|-----------|------------|
| `gitops-argocd` | `argo-cd` 9.4.7 | `argocd` | `identity-keycloak-config` |
| `gitops-argocd-manifests` | raw bundle | `argocd` | `identity-keycloak-config` |
| `gitops-argo-rollouts` | `argo-rollouts` 2.40.6 | `argo-rollouts` | `identity-keycloak-config` |
| `gitops-argo-rollouts-manifests` | raw bundle | `argo-rollouts` | `gitops-argo-rollouts` |
| `gitops-argo-workflows` | `argo-workflows` 0.47.4 | `argo-workflows` | `identity-keycloak-config` |
| `gitops-argo-workflows-manifests` | raw bundle | `argo-workflows` | `gitops-argo-workflows` |
| `gitops-analysis-templates` | raw bundle | `argo-rollouts` | `identity-keycloak-config` |

### 50-gitlab (depends on pki + identity + harbor)

| HelmOp | Chart / Bundle | Namespace | Depends on |
|--------|---------------|-----------|------------|
| `gitlab-cnpg` | raw bundle | `database` | `identity-keycloak-config`, `operators-cnpg` |
| `gitlab-redis` | raw bundle | `gitlab` | `identity-keycloak-config`, `operators-redis` |
| `gitlab-core` | `gitlab` 9.9.2 | `gitlab` | `gitlab-cnpg`, `gitlab-redis`, `harbor-core` |
| `gitlab-manifests` | raw bundle | `gitlab` | `identity-keycloak-config` |
| `gitlab-runners` | raw bundle | `gitlab-runners` | `gitlab-core` |

---

## Step 4: Post-Deploy — Intermediate CA Signing

After Phase 4 (HelmOp creation), Fleet deploys `pki-vault` and `pki-vault-init`
to the downstream cluster. The `vault-init` Job initializes Vault and generates
an intermediate CA CSR.

Phase 5 of `deploy.sh` handles this automatically:

1. Waits for the `vault-intermediate-csr` Secret to appear (up to 10 minutes)
2. Extracts the CSR PEM from the Secret
3. Signs it locally with the offline Root CA key (`openssl x509 -req`)
4. Imports the signed chain (`intermediate + root`) into Vault `pki_int/`
5. Configures the PKI signing role for cert-manager

After Phase 5 completes, **return the Root CA key to offline storage.** It is
not needed again unless the intermediate CA expires (15-year validity).

---

## Step 5: Post-Deploy — Vault Secret Seeding

Phase 5.5 seeds initial service credentials into Vault KV v2. All passwords
are randomly generated (32-char alphanumeric). The operation is idempotent
(write-once; existing keys are not overwritten).

Secrets seeded:

| Vault KV path | Service |
|---------------|---------|
| `kv/services/database/keycloak-pg` | Keycloak PostgreSQL |
| `kv/services/database/harbor-pg` | Harbor PostgreSQL |
| `kv/services/database/grafana-pg` | Grafana PostgreSQL |
| `kv/services/keycloak/admin-secret` | Keycloak bootstrap admin |
| `kv/services/keycloak/platform-admin` | Platform admin user |
| `kv/services/harbor/admin-password` | Harbor admin |
| `kv/services/minio/credentials` | MinIO root credentials |
| `kv/services/monitoring/grafana-admin` | Grafana admin |
| `kv/services/gitlab/postgres-password` | GitLab PostgreSQL |
| `kv/services/gitlab/minio-storage` | GitLab object storage |
| `kv/services/gitlab-runners/harbor-ci-push` | CI image push credentials |

ExternalSecret CRs in each service namespace pull these secrets from Vault
automatically once the ESO SecretStores are configured.

---

## Step 6: Validate Deployment

### Check HelmOp status

```bash
./deploy.sh --status
```

This shows the state of all 37 HelmOps and their corresponding Fleet bundles.
All entries should show `active` state with `1/1` ready.

You can also check directly:

```bash
./deploy-fleet-helmops.sh --status
```

### Rancher UI

Navigate to **Continuous Delivery > App Bundles** in the Rancher UI to see
the graphical deployment status with dependency arrows.

### Downstream cluster verification

Generate a kubeconfig for the downstream cluster and verify key workloads:

```bash
# Vault is initialized and unsealed
kubectl -n vault exec vault-0 -- vault status

# cert-manager ClusterIssuer is Ready
kubectl get clusterissuer vault-issuer -o jsonpath='{.status.conditions[0].status}'

# ESO controller is running
kubectl -n external-secrets get deploy external-secrets -o jsonpath='{.status.readyReplicas}'

# Keycloak is healthy
kubectl -n keycloak get deploy keycloak

# Prometheus stack is running
kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus

# Harbor core is running
kubectl -n harbor get deploy harbor-core

# ArgoCD is running
kubectl -n argocd get deploy argocd-server

# GitLab webservice is running
kubectl -n gitlab get deploy gitlab-webservice-default
```

---

## Day-2 Operations

### Re-deploying a single group

```bash
./deploy.sh --skip-push --group 20-monitoring
```

Or target the HelmOps directly:

```bash
./deploy-fleet-helmops.sh --group 30-harbor
```

### Deleting all HelmOps

```bash
./deploy.sh --delete
```

This removes all HelmOp CRs from the management cluster and cleans up any
leftover Bundle CRs from previous deployment approaches.

### Updating chart versions

1. Update the version in the `HELMOP_DEFS` array in `deploy-fleet-helmops.sh`
2. Push the new chart version to Harbor: `./push-charts.sh`
3. Re-run the deployment: `./deploy-fleet-helmops.sh`

Fleet detects the version change and rolls out the update on the downstream
cluster.

### Updating raw manifest bundles

1. Edit the manifests under `fleet-gitops/<group>/<bundle>/`
2. Bump `BUNDLE_VERSION` in `.env` (or export it)
3. Push bundles: `./push-bundles.sh`
4. Re-run the deployment: `./deploy-fleet-helmops.sh`

---

## Troubleshooting

### HelmOp stuck in `NotReady` or `WaitApplied`

Check the Fleet controller logs on the management cluster:

```bash
kubectl -n cattle-fleet-system logs -l app=fleet-controller --tail=100
```

Check the downstream fleet-agent logs:

```bash
kubectl -n cattle-fleet-system logs -l app=fleet-agent --tail=100
```

### Dependency not satisfied

If a HelmOp is waiting on a dependency, check the upstream HelmOp status:

```bash
./deploy-fleet-helmops.sh --status
```

The dependency chain must be fully `active` before downstream HelmOps deploy.

### harbor-helm-ca Secret missing

The `deploy-fleet-helmops.sh` script auto-creates this Secret by extracting
the CA from Harbor's TLS chain. If it fails (e.g., Harbor uses a public CA),
create it manually:

```bash
kubectl -n fleet-default create secret generic harbor-helm-ca \
  --from-file=cacerts=/path/to/ca-bundle.pem \
  --from-literal=username=admin \
  --from-literal=password='<harbor-password>'
```

### Vault pods stuck in `0/1 Running`

Vault pods start sealed. The `pki-vault-unsealer` bundle deploys a CronJob
that auto-unseals Vault on pod restart. If it has not run yet:

```bash
kubectl -n vault get cronjob vault-unsealer
kubectl -n vault create job --from=cronjob/vault-unsealer manual-unseal
```

### Phase 5 times out waiting for CSR

The `vault-init` Job must complete before Phase 5 can sign the intermediate
CSR. Check the Job status:

```bash
kubectl -n vault get jobs
kubectl -n vault logs job/vault-init
```

Common causes: Vault is not unsealed, or the `pki-vault-init` bundle has not
deployed yet (check Fleet status).
