# Getting Started

This guide walks through deploying a complete production platform to an RKE2 cluster using Fleet GitOps. A single `deploy.sh` command orchestrates the entire deployment across 9 bundle groups (65 total bundles), including Vault PKI signing and CI secret seeding, in one seamless workflow.

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
   - (Optional) `HARVESTER_KUBECONFIG_PATH` — path to Harvester kubeconfig for terraform-runner builds
   - `CI_SERVICE_USER`, `CI_SERVICE_NAME`, `CI_SERVICE_EMAIL` — CI service account identity (created in Keycloak)
   - `CI_DEPLOY_PRIVATE_KEY_FILE` — path to SSH deploy key private key file
   - `CI_DEPLOY_PUBLIC_KEY_FILE` — path to SSH deploy key public key file
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
| 4 | Create 65 Fleet HelmOps on Rancher management cluster | ~5 min |
| 5 | Sign Vault intermediate CSR with offline Root CA, import into Vault | ~15 min (waits for vault-init) |
| 6 | Seed manual secrets (GitLab license, golden-image-watcher, Harvester kubeconfig) | ~1 min |

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

All 65 bundles deploy in strict dependency order across 9 bundle groups. Fleet's `dependsOn` field ensures proper sequencing.

### Bundle Structure (65 total across 9 groups)

**00-operators** (8 bundles) — Base operators, no dependencies
- Prometheus CRDs, CNPG, Redis Operator, cluster-autoscaler, storage-autoscaler, node-labeler, overprovisioning, Gateway API CRDs

**05-pki-secrets** (8 bundles) — PKI and secrets foundation
- cert-manager, Vault HA, vault-init (Raft initialization), vault-unsealer, vault-pki-issuer, External Secrets Operator, Vault bootstrap store

**10-identity** (4 bundles) — User authentication and authorization
- Keycloak CNPG, keycloak-init, Keycloak server, Keycloak OIDC configuration

**11-infra-auth** (3 bundles) — Auth for infrastructure services
- Traefik auth gateway, Vault auth proxy, Hubble auth proxy

**15-dns** (1 bundle) — DNS automation
- external-dns-secrets (ExternalSecret for DNS provider credentials)

**20-monitoring** (7 bundles) — Observability stack
- monitoring-init (consolidates cluster config), Grafana CNPG, secrets, Loki, Alloy collector, Prometheus+Grafana+Alertmanager

**30-harbor** (7 bundles) — Container registry
- MinIO object storage, harbor-init (bootstrap), secrets, CNPG, Valkey cache, Harbor core, manifests

**35-backup** (3 bundles) — Cross-cluster backup storage
- backup-minio (dedicated MinIO at `backup.<DOMAIN>`, S3-only), backup-init (bucket + credential provisioning), backup-manifests (Gateway, HTTPRoute, VolumeAutoscaler)

**40-gitops** (12 bundles) — Progressive delivery platform
- ArgoCD (init, credentials, core, manifests, GitLab setup), Argo Rollouts (init, core, manifests), Argo Workflows (init, core, manifests), analysis templates

**50-gitlab** (10 bundles) — Source control and CI/CD
- gitlab-init, gitlab-cnpg, gitlab-redis, gitlab-credentials (seeds CI secrets), gitlab-core, gitlab-ready, gitlab-manifests, gitlab-runners (executor), gitlab-runner-shared, gitlab-runner-terraform

**60-cicd-onboard** (3 bundles) — App platform onboarding
- onboard-rbac (shared RBAC for onboarding jobs), onboard-identity-portal, onboard-forge

### Key Dependency Insights

- **01 before 05**: Operators (CNPG, Redis) must deploy before PKI uses them
- **05 before 10-11-20-30-40-50**: PKI provides TLS certs and secret storage for everything else
- **10 before 11-20-30-40-50**: Keycloak must be ready first, everything else uses OIDC
- **11 before 15-20-30-40**: Infrastructure auth proxies wait for Keycloak configuration
- **15-dns**: External DNS secrets depend on infra-auth
- **20-30-40 parallel**: Monitoring, Harbor, and GitOps can deploy in parallel once auth is ready
- **30 before 35**: Backup MinIO depends on Harbor for TLS infrastructure
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

Creates 65 HelmOp CRs on the Rancher management cluster. Each HelmOp references either:
- An upstream Helm chart at `oci://harbor.<DOMAIN>/helm/<chart>`
- A raw manifest bundle at `oci://harbor.<DOMAIN>/fleet/<bundle>`

Fleet controller reconciles these CRs and synchronizes deployments to the downstream cluster in dependency order.

### Phase 5: Sign Vault Intermediate CSR (Post-Deploy)

After Phase 4 creates the HelmOps, the `pki-vault-init` Job deploys and generates a certificate signing request (CSR). Phase 5 (post-deploy):

1. Waits for vault-0 pod ready + vault-init Job completion (up to 15 minutes total)
2. Extracts the `vault-intermediate-csr` Secret from the downstream cluster
3. Signs it locally with the offline Root CA key using OpenSSL (on deployment machine)
4. Imports the signed chain (`intermediate + root`) back into Vault PKI mount
5. Configures Vault's `default` signing role to allow cert-manager to issue certificates

**Critical:** Return the Root CA key to offline storage after this phase completes. It's not needed again unless the intermediate CA expires (15-year validity).

### Phase 6: Seed Manual Secrets

Seeds credentials that must be manually provided (not auto-generated):

| Secret | Vault Path | Purpose |
|--------|-----------|---------|
| GitLab license activation code | `kv/services/gitlab/activation-code` | GitLab EE licensing (if `GITLAB_LICENSE` set in `.env`) |
| Golden image watcher credentials | `kv/services/ci/golden-image-watcher` | GitLab service account for golden image build pipeline |
| Harvester kubeconfig | `kv/services/ci/harvester-kubeconfig` | Kubeconfig for terraform-runner to orchestrate Harvester builds |

All other service credentials are auto-generated by deployment scripts and External Secrets Operator.

---

## Step 4: Monitor Deployment Progress

### Real-time status watch

```bash
./deploy.sh --watch
```

Shows live updates of all 65 HelmOps. Exits when all are `active` and ready.

### One-time status check

```bash
./deploy.sh --status
```

Shows the current state of all HelmOps.

### Rancher UI

Navigate to **Continuous Delivery > App Bundles** in the Rancher Fleet dashboard. You'll see:
- All 65 bundles with their deployment status
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

## Multi-Cluster Deployment (Test/CI)

The `BUNDLE_PREFIX` variable enables multiple cluster deployments (prod + test) to coexist in the same `fleet-default` namespace. Environment-specific configuration lives in separate `.env` files:

| File | `BUNDLE_PREFIX` | Purpose |
|------|----------------|---------|
| `.env.rke2-prod` | `''` (empty) | Production cluster (default, zero behavioral change) |
| `.env.rke2-test` | `test-` | Test cluster |

### How it works

When `BUNDLE_PREFIX` is set, all HelmOp names, `dependsOn` references, and raw bundle OCI paths (`/fleet/`) are prefixed. Upstream Helm chart OCI paths (`/helm/`) are NOT prefixed since charts are shared across environments. Each environment maintains its own `BUNDLE_VERSION`.

### Deploy to a test cluster

1. Copy the target environment file: `cp .env.rke2-test .env`
2. Push prefixed bundles: `./scripts/push-bundles.sh`
3. Deploy by group: `./scripts/deploy-fleet-helmops.sh --group 00-operators`
4. Restore prod config when done: `cp .env.rke2-prod .env`

### Verify prefixed deployments

In the Rancher Fleet dashboard under **Continuous Delivery > App Bundles**, test cluster HelmOps appear with the `test-` prefix (e.g., `test-operators-cnpg`, `test-pki-vault`).

### Clean up test deployments

The `--purge` flag respects the prefix and deletes only prefixed artifacts:

```bash
cp .env.rke2-test .env
./scripts/deploy-fleet-helmops.sh --purge
cp .env.rke2-prod .env
```

---

## Day-2 Operations

### Monitor ongoing deployment

```bash
./deploy.sh --watch
```

Continuously updates status until all bundles are ready. Press Ctrl+C to stop.

### Targeted Updates (Single Service Changes)

When you change a single service or bundle group, use targeted deploys instead of full redeploys.

> **Note:** `deploy.sh` automatically deletes completed init Jobs before deploying, so you no longer need to manually clean them up. When using `--group`, only Jobs belonging to that group are cleaned. This prevents the `cannot patch` errors that previously occurred when Fleet tried to update immutable completed Jobs.

**Targeted update workflow:**

1. Edit the template or values under `fleet-gitops/<group>/<bundle>/`
2. Bump `BUNDLE_VERSION` in `.env` (e.g., `1.0.0` → `1.0.1`)
3. Deploy only the affected group:

```bash
./deploy.sh --skip-charts --group <group>
```

The `--skip-charts` flag skips re-pushing upstream Helm charts (which rarely change). The script still pushes raw manifest bundles and creates/updates HelmOps, but only for the specified group.

**Why BUNDLE_VERSION must always be bumped:** Fleet pulls bundles from Harbor as OCI artifacts tagged with `BUNDLE_VERSION`. Without a new version tag, Fleet sees no change in the OCI registry and will not pull updated artifacts, even if the bundle contents changed.

**Available bundle groups:**

| Group | Contents |
|-------|----------|
| `00-operators` | CNPG, Redis Operator, cluster-autoscaler, node-labeler, overprovisioning |
| `05-pki-secrets` | Vault, cert-manager, ESO, vault-init, vault-unsealer |
| `10-identity` | Keycloak CNPG, Keycloak server, Keycloak OIDC config |
| `11-infra-auth` | Traefik auth gateway, Vault auth proxy, Hubble auth proxy |
| `15-dns` | External DNS secrets |
| `20-monitoring` | Prometheus, Grafana, Loki, Alloy, monitoring-init |
| `30-harbor` | MinIO, Harbor core, CNPG, Valkey, harbor-init |
| `35-backup` | Backup MinIO, bucket provisioning, VolumeAutoscaler |
| `40-gitops` | ArgoCD, Argo Rollouts, Argo Workflows |
| `50-gitlab` | GitLab, Runners, CNPG, Redis, gitlab-credentials |
| `60-cicd-onboard` | App platform onboarding (RBAC, per-app Harbor/Keycloak setup) |

**Example — update ArgoCD configuration:**

```bash
# 1. Edit ArgoCD values
vim fleet-gitops/40-gitops/argocd-core/values.yaml

# 2. Bump bundle version
sed -i 's/BUNDLE_VERSION=.*/BUNDLE_VERSION=1.0.2/' fleet-gitops/scripts/.env

# 3. Deploy only the gitops group
cd fleet-gitops/scripts
./deploy.sh --skip-charts --group 40-gitops
```

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
3. Push updated bundles: `./push-bundles.sh`
4. Re-run deployment: `./deploy.sh --skip-push --group 20-monitoring`

> Completed init Jobs are auto-cleaned before deploy. Use `./cleanup-completed-jobs.sh` only if you need to manually clean up failed or stuck Jobs.

### Delete all HelmOps and namespaces

To completely remove the platform deployment:

```bash
./deploy.sh --delete
```

This:
- Removes all 65 HelmOp CRs from the Rancher management cluster
- Uninstalls all Helm releases on the downstream cluster
- Deletes all Fleet-managed CRDs (CNPG, External Secrets, cert-manager, etc.)
- Deletes all Fleet-managed namespaces (except kube-system, kube-public, kube-node-lease)

Optionally also purge Harbor OCI artifacts:

```bash
./deploy-fleet-helmops.sh --purge
```

---

## App Onboarding Workflow

The `60-cicd-onboard` bundle group automates platform onboarding for new applications. Each app gets a dedicated onboarding Job that provisions Harbor projects, Keycloak clients, ArgoCD AppProjects, and Vault secrets paths.

### How Onboarding Works

1. **Create an onboarding bundle** under `fleet-gitops/60-cicd-onboard/onboard-<APP>/` with manifests for the onboarding Job
2. **Register the HelmOp** in `deploy-fleet-helmops.sh` with dependencies on `harbor-init`, `identity-keycloak-config`, and `onboard-rbac`
3. **Deploy** via `./deploy.sh --group 60-cicd-onboard`

The onboarding Job provisions:

| Resource | Location | Purpose |
|----------|----------|---------|
| Harbor project | `harbor.<DOMAIN>` | Container image storage for `<TEAM>/<APP>` |
| Keycloak client | `keycloak.<DOMAIN>` | OIDC client for app-specific authentication |
| Vault KV path | `kv/apps/<TEAM>/<APP>` | App secrets storage |
| ArgoCD AppProject | `argocd.<DOMAIN>` | Scoped deployment permissions |

### MinimalCD Promotion Flow

Applications deployed through ArgoCD follow a three-environment promotion model:

```
dev (auto-sync) ──MR──▶ staging (MR merge) ──MR + manual sync──▶ prod
```

| Environment | Trigger | Sync Policy | Approval |
|-------------|---------|-------------|----------|
| `dev` | Push to `main` | Auto-sync | None (automatic) |
| `staging` | Merge request to `staging` overlay | Auto-sync on MR merge | MR approval required |
| `prod` | Merge request to `prod` overlay | Manual sync | MR approval + manual ArgoCD sync |

Each environment is an ArgoCD Application pointing at a different overlay directory in the `platform-deployments` repo:

```
platform-deployments/
  apps/<TEAM>/<APP>/
    base/                 # Shared manifests (Deployment, Service, etc.)
    overlays/
      dev/                # kustomization.yaml — auto-synced
      staging/            # kustomization.yaml — MR-gated
      prod/               # kustomization.yaml — MR + manual sync
```

The `deploy-version` annotation on each ArgoCD Application tracks which image tag or commit is deployed per environment. ArgoCD shows this in the UI, enabling quick verification of what version is running where.

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

### Phase 5 times out waiting for Vault CSR (>15 min)

Phase 5 waits up to 15 minutes for vault-0 to be ready and the vault-init Job to complete. If this times out, check the downstream cluster:

```bash
# Check if vault-0 pod is running
kubectl -n vault get pods vault-0

# Check vault-init Job logs
kubectl -n vault logs job/vault-init

# Check if vault-0 is sealed or initialized
kubectl -n vault exec vault-0 -- vault status
```

Common causes:
- **Vault pods not running yet**: Fleet is still pulling and installing bundles. Wait for 05-pki-secrets bundle group to complete on Rancher.
- **Vault is sealed**: The `pki-vault-unsealer` CronJob should auto-unseal every 2 minutes. Check logs: `kubectl -n vault logs cronjob/vault-unsealer`
- **CNPG database not ready**: Vault requires the Raft storage cluster. Check `kubectl -n vault get pvc` — if pending, wait for storage provisioning.
- **vault-init Job failed**: Check `kubectl -n vault describe job vault-init` and logs for errors.

**If Phase 5 times out:** The script will skip CSR signing and log a warning. Re-run `./deploy.sh --group 05-pki-secrets` to retry Phase 5 after the Vault cluster stabilizes.

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
