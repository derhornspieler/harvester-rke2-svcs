# Getting Started

This guide walks through deploying a complete production platform to an RKE2 cluster using Fleet GitOps. A single `deploy.sh` command orchestrates the entire deployment across 58 bundles, including Vault PKI signing and CI secret seeding, in one seamless workflow.

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

### Configuration (prepare.sh)

The `prepare.sh` script sets up your environment interactively. Run it first:

```bash
cd fleet-gitops
./scripts/prepare.sh
```

This script:
1. **Bootstraps `.env`** from `.env.example` if `.env` doesn't exist
2. **Prompts for credentials** (shows current value, press Enter to keep, type to override):
   - `RANCHER_URL` — management cluster API URL
   - `HARBOR_HOST` — OCI registry hostname (e.g., `harbor.example.com`)
   - `HARBOR_USER` — registry username
   - `HARBOR_PASS` — registry password
   - `DOMAIN` — cluster domain (e.g., `example.com`)
   - `FLEET_TARGET_CLUSTER` — downstream cluster name in Rancher
   - `TRAEFIK_LB_IP` — Traefik LoadBalancer IP
   - (Optional) `GITLAB_LICENSE` — GitLab license activation code
   - (Optional) `HARVESTER_KUBECONFIG_PATH` — path to Harvester kubeconfig for golden image builds
3. **Manages Rancher API token lifecycle** — logs in with username/password, deletes old `fleet-gitops-deploy` tokens, creates a new no-expiry global-scope API token
4. **Validates** — Rancher API access, Harbor access, Root CA files

**Refresh your Rancher token anytime it expires:**

```bash
./scripts/prepare.sh --token-only
```

This skips `.env` prompts and only refreshes the Rancher API token.

---

## Step 0: Prepare Environment

Before any deployment, set up your environment configuration:

```bash
cd fleet-gitops
./scripts/prepare.sh
```

This creates `.env` with all required variables and validates your setup. You only need to run this once; use `--token-only` to refresh the Rancher token later.

---

## Step 1: Deploy All Bundles

The unified deployment script handles everything in sequence:

```bash
cd fleet-gitops/scripts
./deploy.sh
```

This command orchestrates **6 automated phases**:

| Phase | What it does | Duration |
|-------|------------|----------|
| 1 | Push Helm charts to Harbor | ~2 min |
| 2 | Seed Root CA on downstream cluster, create namespaces, prepare cluster-autoscaler | ~3 min |
| 3 | Push raw manifest bundles to Harbor | ~2 min |
| 4 | Create 58 Fleet HelmOps on Rancher management cluster | ~5 min |
| 5 | Sign Vault intermediate CSR with offline Root CA, import into Vault | ~15 min (waits for vault-init) |
| 6 | Seed manual secrets (GitLab license, golden image watcher, Harvester kubeconfig) | ~1 min |

**Total deployment time:** ~30-40 minutes (depending on network and cluster performance)

### Skip pushing charts/bundles if already in Harbor

```bash
./deploy.sh --skip-push
```

### Dry run (show HelmOps without applying)

```bash
./deploy.sh --dry-run
```

### Deploy single group only

```bash
./deploy.sh --group 00-operators
```

### Delete all HelmOps

```bash
./deploy.sh --delete
```

---

## Step 2: Understand Bundle Deployment Order

All 58 bundles deploy in strict dependency order across 7 bundle groups. Fleet's `dependsOn` field ensures proper sequencing.

### Bundle Structure (58 total)

**00-operators** (8 bundles) — Base operators, no dependencies
- Prometheus CRDs, CNPG, Redis Operator, cluster-autoscaler, storage-autoscaler, node-labeler, overprovisioning, Gateway API CRDs

**05-pki-secrets** (8 bundles) — PKI and secrets foundation
- cert-manager, Vault HA, vault-init (Raft initialization), vault-unsealer, vault-pki-issuer, External Secrets Operator, Vault bootstrap store

**10-identity** (3 bundles) — User authentication and authorization
- Keycloak CNPG, Keycloak server, Keycloak OIDC configuration

**11-infra-auth** (3 bundles) — Auth for infrastructure services
- Traefik auth gateway, Vault auth proxy, Hubble auth proxy

**20-monitoring** (7 bundles) — Observability stack
- monitoring-init (consolidates cluster config), Grafana CNPG, secrets, Loki, Alloy collector, Prometheus+Grafana+Alertmanager

**30-harbor** (7 bundles) — Container registry
- MinIO object storage, harbor-init (bootstrap), secrets, CNPG, Valkey cache, Harbor core, manifests

**40-gitops** (9 bundles) — Progressive delivery platform
- ArgoCD (init, credentials, core, manifests, GitLab setup), Argo Rollouts (init, core, manifests), Argo Workflows (init, core, manifests), analysis templates

**50-gitlab** (13 bundles) — Source control and CI/CD
- gitlab-init, gitlab-cnpg, gitlab-redis, gitlab-credentials (seeds CI secrets), gitlab-core, gitlab-ready, gitlab-manifests, gitlab-runners (executor), gitlab-runner-shared, gitlab-runner-golden-image

### Key Dependency Insights

- **01 before 05**: Operators (CNPG, Redis) must deploy before PKI uses them
- **05 before 10-11-20-30-40-50**: PKI provides TLS certs and secret storage for everything else
- **10 before 11-20-30-40-50**: Keycloak must be ready first, everything else uses OIDC
- **11 before 20-30-40**: Infrastructure auth proxies wait for Keycloak configuration
- **20-30-40 parallel**: Monitoring, Harbor, and GitOps can deploy in parallel once auth is ready
- **30 before 50**: Harbor must be ready before GitLab pushes to it
- **gitlab-credentials right after gitlab-redis**: Seeds CI secrets early so harbor-core and runners can pull them

---

## Step 3: What Each Phase Does

### Phase 1: Push Helm Charts

Pulls upstream charts (Vault, Prometheus, ArgoCD, GitLab, etc.) and pushes them to Harbor OCI registry at `oci://harbor.<DOMAIN>/helm/`.

```bash
./push-charts.sh
```

### Phase 2: Seed Root CA and Prepare Cluster

- Creates/updates Root CA Secret in `cert-manager` namespace
- Creates ConfigMap in `kube-system` for infrastructure authentication
- Pre-creates namespaces: `vault`, `monitoring`, `external-secrets`, `cluster-autoscaler`
- Seeds cluster-autoscaler cloud config (Rancher API credentials)
- Applies Traefik HelmChartConfig (dashboard, Gateway API, CA trust)

This happens on the downstream cluster before HelmOps are created.

### Phase 3: Push Raw Manifest Bundles

Packages Kubernetes manifests from `fleet-gitops/<group>/<bundle>/` as OCI artifacts and pushes to Harbor at `oci://harbor.<DOMAIN>/fleet/`.

Includes all init jobs, secrets, CRDs, and configurations.

### Phase 4: Create Fleet HelmOps

Creates 58 HelmOp CRs on the Rancher management cluster. Each HelmOp references either:
- An upstream Helm chart at `oci://harbor.<DOMAIN>/helm/<chart>`
- A raw manifest bundle at `oci://harbor.<DOMAIN>/fleet/<bundle>`

Fleet controller reconciles these CRs and synchronizes deployments to the downstream cluster in dependency order.

### Phase 5: Sign Vault Intermediate CSR

After `pki-vault-init` deploys to the cluster, it generates a certificate signing request (CSR). Phase 5:

1. Waits for the `vault-intermediate-csr` Secret (up to 10 minutes)
2. Extracts CSR PEM
3. Signs it locally with the offline Root CA key using OpenSSL
4. Imports the signed chain (`intermediate + root`) into Vault
5. Configures Vault PKI role for certificate issuance

**Critical:** Return the Root CA key to offline storage after this phase completes. It's not needed again unless the intermediate CA expires (15-year validity).

### Phase 6: Seed Manual Secrets

Seeds credentials that must be manually provided (not auto-generated):

| Secret | Vault Path | Purpose |
|--------|-----------|---------|
| GitLab license activation code | `kv/services/gitlab/activation-code` | GitLab EE licensing (if `GITLAB_LICENSE` set in `.env`) |
| Golden image watcher credentials | `kv/services/ci/golden-image-watcher` | GitLab service account for golden image build pipeline |
| Harvester kubeconfig | `kv/services/ci/harvester-kubeconfig` | Kubeconfig for golden-image-builder runner to orchestrate Harvester builds |

All other service credentials are auto-generated by deployment scripts and External Secrets Operator.

---

## Step 4: Monitor Deployment Progress

### Real-time status watch

```bash
./deploy.sh --watch
```

Shows live updates of all 58 HelmOps. Exits when all are `active` and ready.

### One-time status check

```bash
./deploy.sh --status
```

Shows the current state of all HelmOps.

### Rancher UI

Navigate to **Continuous Delivery > App Bundles** in the Rancher Fleet dashboard. You'll see:
- All 58 bundles with their deployment status
- Dependency arrows showing the deployment order
- Real-time sync state (updated/pending/error)

### Verify key workloads on downstream cluster

```bash
# Vault is initialized and unsealed
kubectl -n vault exec vault-0 -- vault status

# cert-manager ClusterIssuer is Ready
kubectl get clusterissuer vault-issuer -o jsonpath='{.status.conditions[0].status}'

# ESO controller is running
kubectl -n external-secrets get deploy external-secrets -o jsonpath='{.status.readyReplicas}'

# Keycloak OIDC is healthy
kubectl -n keycloak get deploy keycloak

# Prometheus stack is running
kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus

# Harbor registry is running
kubectl -n harbor get deploy harbor-core

# ArgoCD is running
kubectl -n argocd get deploy argocd-server

# GitLab webservice is running
kubectl -n gitlab get deploy gitlab-webservice-default
```

---

## Day-2 Operations

### Monitor ongoing deployment

```bash
./deploy.sh --watch
```

Continuously updates status until all bundles are ready. Press Ctrl+C to stop.

### Re-deploy a single bundle group

To redeploy only one group (e.g., after fixing a bug in monitoring stack):

```bash
./deploy.sh --skip-push --group 20-monitoring
```

This skips the chart/bundle push phase and re-creates only HelmOps in that group.

### Update an upstream Helm chart version

To upgrade, e.g., Prometheus stack to a new version:

1. Edit the chart version in `deploy-fleet-helmops.sh` (look for `OCI_CHART_PROMETHEUS_STACK` or `CHART_VER_PROMETHEUS_STACK`)
2. Push the new version: `./push-charts.sh`
3. Re-run deployment: `./deploy.sh --skip-push --group 20-monitoring`

Fleet detects the version change and rolls out the update.

### Update a raw manifest bundle

To change manifests in, e.g., monitoring-init bundle:

1. Edit manifests under `fleet-gitops/20-monitoring/monitoring-init/`
2. Bump `BUNDLE_VERSION` in `.env` (e.g., from `1.0.0` to `1.0.1`)
3. (Optional) Clean up completed Jobs first: `./cleanup-completed-jobs.sh` (prevents Fleet immutability conflicts)
4. Push updated bundles: `./push-bundles.sh`
5. Re-run deployment: `./deploy.sh --skip-push --group 20-monitoring`

### Delete all HelmOps and namespaces

To completely remove the platform deployment:

```bash
./deploy.sh --delete
```

This:
- Removes all 58 HelmOp CRs from the Rancher management cluster
- Uninstalls all Helm releases on the downstream cluster
- Deletes all Fleet-managed CRDs (CNPG, External Secrets, cert-manager, etc.)
- Deletes all Fleet-managed namespaces (except kube-system, kube-public, kube-node-lease)

Optionally also purge Harbor OCI artifacts:

```bash
./deploy-fleet-helmops.sh --purge
```

---

## Troubleshooting

### Rancher token expired or invalid

If `deploy.sh` fails with "invalid token" or "401 Unauthorized":

```bash
./scripts/prepare.sh --token-only
```

This refreshes your Rancher API token without re-entering configuration.

### HelmOp stuck in `NotReady` or `WaitApplied`

Check the Fleet controller logs on the management cluster:

```bash
kubectl -n cattle-fleet-system logs -l app=fleet-controller --tail=100 -f
```

Check the downstream fleet-agent logs:

```bash
kubectl -n cattle-fleet-system logs -l app=fleet-agent --tail=100 -f
```

Common causes:
- **Dependency not ready**: Check upstream HelmOp status: `./deploy.sh --status`
- **Resource quota exceeded**: Check namespace limits: `kubectl describe ns <namespace>`
- **Image not found in Harbor**: Verify charts/bundles were pushed: `helm ls -n fleet-default`

### Phase 5 times out waiting for Vault CSR

The `pki-vault-init` Job must complete before Phase 5 can sign the intermediate CSR. Check the Job status:

```bash
kubectl -n vault get jobs
kubectl -n vault logs job/vault-init
```

Common causes:
- Vault pod is not running yet (Fleet is still syncing)
- Vault is unhealthy (check `kubectl -n vault logs vault-0`)
- CNPG database is not ready for Vault to connect

Wait for `pki-vault` HelmOp to be fully active:

```bash
./deploy.sh --status | grep pki-vault
```

All three should show `active` before Phase 5 signs the CSR.

### Vault pods stuck in `0/1 Running`

Vault pods start sealed. The `pki-vault-unsealer` CronJob auto-unseals them. If not unsealed after 5 minutes:

```bash
# Manually trigger unsealer job
kubectl -n vault create job --from=cronjob/vault-unsealer vault-unsealer-manual
kubectl -n vault logs job/vault-unsealer-manual
```

After unsealing, Vault should transition to `1/1 Running`.

### harbor-helm-ca Secret missing

The `deploy-fleet-helmops.sh` script auto-creates this Secret from Harbor's TLS chain. If auto-creation fails, create manually:

```bash
# Extract Harbor's root CA
openssl s_client -connect harbor.example.com:443 -showcerts < /dev/null 2>/dev/null | \
  sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' | tail -1 > /tmp/harbor-ca.pem

# Create secret on management cluster
kubectl -n fleet-default create secret generic harbor-helm-ca \
  --from-file=cacerts=/tmp/harbor-ca.pem \
  --from-literal=username=<HARBOR_USER> \
  --from-literal=password='<HARBOR_PASS>'
```

### GitLab webservice stuck in CrashLoopBackOff

Common issue: The `deployment.livenessProbe` path in gitlab-core values is incorrect. Check the correct path:

```bash
kubectl -n gitlab describe deploy gitlab-webservice-default
```

Look for probe configuration. The correct structure is:
```yaml
webservice:
  deployment:
    livenessProbe:
      initialDelaySeconds: 30
      timeoutSeconds: 5
      periodSeconds: 10
```

### ExternalSecret stuck in `SecretSyncError`

Check if the secret exists in Vault:

```bash
kubectl -n <namespace> describe externalsecret <name>
kubectl -n vault exec vault-0 -- vault kv get kv/services/<service>/<secret>
```

If the secret doesn't exist, seed it manually or wait for the init Job to create it. Check init Job logs:

```bash
kubectl -n vault logs job/<bundle>-init
```

### Harbor Valkey password not injected into harbor-core HelmOp

The deploy-fleet-helmops.sh script injects the Valkey password at deploy time. If the password is not found, you'll see a warning in the logs. To fix:

1. Ensure harbor-valkey HelmOp is active
2. Verify the secret exists on the downstream cluster: `kubectl -n harbor get secret harbor-valkey-credentials`
3. Re-run deployment: `./deploy.sh --skip-push`

The script will fetch the Valkey password and inject it into harbor-core values.
