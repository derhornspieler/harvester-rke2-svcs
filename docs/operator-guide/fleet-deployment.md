# Fleet Deployment Guide

This guide walks through deploying all 9 Fleet bundle groups (65 total bundles) to your RKE2 cluster using Rancher Fleet. For a faster getting-started path, see [Getting Started](../getting-started.md) which uses the unified `deploy.sh` script. This guide shows the step-by-step details of the underlying deployment process. Clusters are provisioned via Rancher API script.

## Prerequisites

### Tools

| Tool | Version | Purpose |
|------|---------|---------|
| `kubectl` | 1.28+ | Kubernetes CLI |
| `helm` | 3.14+ | Helm chart management |
| `jq` | 1.6+ | JSON processing |
| `openssl` | 1.1.1+ | Certificate generation |
| `git` | 2.36+ | Version control |

Verify all tools:

```bash
kubectl version --client
helm version --short
jq --version
openssl version
git --version
```

### Cluster Requirements

- RKE2 cluster (v1.28+) with 13 nodes minimum
  - 3 controlplane nodes
  - 4 database nodes (labeled `workload-type: database`)
  - 4 general nodes (labeled `workload-type: general`)
  - 2 compute nodes (labeled `workload-type: compute`)
- Cluster-admin kubeconfig access
- Rancher installed with Fleet enabled

### Domain & TLS

- Domain name (e.g., `example.com`)
- Ability to create DNS A records for `*.example.com`
- (Root CA will be created offline during setup)

## Overview: The 9 Bundle Groups (65 Total Bundles)

Bundle groups deploy in strict order, each depending on previous ones. For detailed bundle structure, see [Platform Overview](../architecture/overview.md).

| Group | Count | Main Bundles | Depends On |
|-------|-------|--------------|------------|
| 00-operators | 8 | CNPG, Redis, node-labeler, storage-autoscaler, cluster-autoscaler, Gateway API CRDs | None |
| 05-pki-secrets | 8 | Vault HA, cert-manager, ESO, vault-init, vault-unsealer, vault-issuer | 00-operators |
| 10-identity | 3 | Keycloak, OAuth2-proxy, Keycloak database (CNPG) | 05-pki-secrets |
| 11-infra-auth | 3 | Auth gateways for Prometheus, Alertmanager, Hubble | 10-identity |
| 20-monitoring | 7 | Prometheus, Grafana, Loki, Alloy, Hubble, Alertmanager | 05-pki-secrets, 11-infra-auth |
| 30-harbor | 7 | Harbor registry, MinIO, Harbor database (CNPG), Valkey cache | 05-pki-secrets, 11-infra-auth |
| 40-gitops | 9 | ArgoCD, Argo Rollouts, Argo Workflows + initialization | 05-pki-secrets, 10-identity, 11-infra-auth |
| 50-gitlab | 13 | GitLab EE, Praefect/Gitaly, Runners, terraform-runner, CNPG, Redis | 05-pki-secrets, 10-identity, 11-infra-auth, 30-harbor |

## Step 1: Prepare Your Environment

### 1.1: Clone the Repository

```bash
git clone https://github.com/your-org/harvester-rke2-svcs.git
cd harvester-rke2-svcs
```

### 1.2: Generate Root CA (Offline, One-Time)

The Root CA is air-gapped and never touched by the cluster. Generate it once:

```bash
cd services/pki
./generate-ca.sh root -o "Your Organization" -d roots/
cd ../..
```

This creates:

- `services/pki/roots/root-ca.crt` — Public root certificate
- `services/pki/roots/root-ca.key` — Private key (store offline, NEVER commit)

**⚠️ Important:** Store `root-ca.key` offline, away from git. You'll only need it once for Vault initialization.

### 1.3: Configure Environment

Fleet bundle values are configured in each bundle group's `fleet.yaml` and associated Helm values files under `fleet-gitops/`. Update domain, passwords, and other configuration in the appropriate bundle group directories before pushing to Harbor.

## Step 2: Push Helm Charts to Harbor

Before deploying bundles, push all Helm charts to Harbor (your internal registry):

```bash
cd fleet-gitops
./scripts/push-charts.sh
# Pushes all Helm charts to harbor.your-domain.com/library/
cd ..
```

Verify charts are available:

```bash
helm repo add harbor https://harbor.your-domain.com/chartrepo/library --username admin --password <harbor-admin-password>
helm repo update
helm search repo harbor/
```

## Step 3: Push Fleet Bundles

Push OCI bundle artifacts:

```bash
cd fleet-gitops
./scripts/push-bundles.sh
# Pushes all bundles to harbor.your-domain.com/oci-bundles/
cd ..
```

## Step 4: Deploy via Fleet GitOps

Deploy HelmOps to the Rancher management cluster:

```bash
cd fleet-gitops
./scripts/deploy-fleet-helmops.sh
cd ..
```

This creates HelmOps resources on the Rancher management cluster, which Fleet
reconciles onto the target downstream cluster.

Watch deployment progress:

```bash
kubectl get bundles -A --watch
kubectl get bundledeployments -A --watch
```

### Expected Timeline

- Bundle 00-operators: ~3 minutes
- Bundle 05-pki-secrets: ~5 minutes (Vault initialization)
- Bundle 10-identity: ~8 minutes (Keycloak startup)
- Bundle 20-monitoring: ~5 minutes
- Bundle 30-harbor: ~8 minutes (MinIO, databases)
- Bundle 40-gitops: ~5 minutes
- Bundle 50-gitlab: ~15 minutes (GitLab startup, runner configuration)

**Total: ~50 minutes** for full platform.

## Step 5: Verify Each Bundle

### Bundle 00-operators

```bash
kubectl get deployment -n kube-system cluster-autoscaler
kubectl get deployment -n kube-system node-labeler
kubectl get deployment -n kube-system storage-autoscaler
# All should have READY 1/1
```

### Bundle 05-pki-secrets

```bash
kubectl get pod -n vault -l app=vault
# Should have 3 replicas ready

kubectl get pod -n cert-manager -l app.kubernetes.io/name=cert-manager
# Should have 1 replica ready

kubectl get clusterissuer vault-issuer
# Should be READY: True
```

### Bundle 10-identity

```bash
kubectl get pod -n keycloak -l app=keycloak
# Should have 3 replicas ready and at least 1 running

kubectl get pod -n keycloak -l app=oauth2-proxy
# Should have 2 replicas ready
```

### Bundle 20-monitoring

```bash
kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus
# Should have 2 replicas ready

kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana
# Should have at least 1 running
```

Access Grafana: `https://grafana.your-domain.com`

### Bundle 30-harbor

```bash
kubectl get pod -n harbor -l app=harbor
# Should have at least 1 running

kubectl get cluster -n harbor
# Should show 3 CNPG clusters in healthy state
```

Access Harbor: `https://harbor.your-domain.com`

### Bundle 40-gitops

```bash
kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-server
# Should be running

kubectl get pod -n argo-rollouts -l app.kubernetes.io/name=argo-rollouts
# Should be running
```

Access ArgoCD: `https://argo.your-domain.com`

### Bundle 50-gitlab

```bash
kubectl get pod -n gitlab -l app=gitlab
# GitLab startup takes 10+ minutes

kubectl get pod -n gitlab-runners -l app=gitlab-runner
# Should have multiple runners ready
```

Access GitLab: `https://gitlab.your-domain.com`

## Step 6: Post-Deployment Configuration

After all bundles are deployed:

1. **Set GitLab root password** (if using default)
2. **Configure GitLab OIDC** (link to Keycloak)
3. **Create project groups** in GitLab matching your teams
4. **Create Keycloak groups** for RBAC
5. **Map GitLab CI runners** to appropriate job categories

See [Day-2 Operations](day2-operations.md) for detailed post-deployment tasks.

## Multi-Cluster Deployment with BUNDLE_PREFIX

The `BUNDLE_PREFIX` variable enables prod and test cluster deployments to coexist in the shared `fleet-default` namespace. Each environment has a dedicated `.env` file:

- `.env.rke2-prod` — `BUNDLE_PREFIX=''` (default, production)
- `.env.rke2-test` — `BUNDLE_PREFIX='test-'` (test cluster)

### Operational Procedure: Test Cluster Deployment

1. **Swap environment config:**

    ```bash
    cd fleet-gitops/scripts
    cp .env.rke2-test .env
    ```

2. **Push prefixed bundles and deploy:**

    ```bash
    ./push-bundles.sh
    ./deploy-fleet-helmops.sh --group 00-operators
    ```

3. **Restore prod config when done:**

    ```bash
    cp .env.rke2-prod .env
    ```

### Verifying Prefixed HelmOps

In the Rancher Fleet dashboard (**Continuous Delivery > App Bundles**), test cluster HelmOps appear with the prefix. For example, `test-operators-cnpg` and `test-pki-vault` alongside the unprefixed prod equivalents.

From the CLI:

```bash
kubectl get helmops -n fleet-default | grep '^test-'
```

### Purging Test Deployments

The `--purge` flag respects the active `BUNDLE_PREFIX` and deletes only matching artifacts:

```bash
cp .env.rke2-test .env
./deploy-fleet-helmops.sh --purge    # deletes only test-* HelmOps and OCI bundles
cp .env.rke2-prod .env               # restore prod config
```

### Key Details

- Upstream Helm chart OCI paths (`/helm/`) are shared across environments and NOT prefixed.
- Raw bundle OCI paths (`/fleet/`) ARE prefixed per environment.
- Each environment maintains its own `BUNDLE_VERSION` independently.

## Troubleshooting

### Bundle stuck in "Pending" state

```bash
kubectl describe bundle 00-operators -n fleet-default
# Check Status and Conditions for details
```

### Helm chart not found

```bash
helm repo add harbor https://harbor.your-domain.com/chartrepo/library --username admin
helm repo update
helm search repo harbor/
```

### Pod CrashLoopBackOff

```bash
kubectl logs <pod-name> -n <namespace>
kubectl describe pod <pod-name> -n <namespace>
```

### Certificate verification errors

```bash
# Check if cert-manager issued certificates
kubectl get certificate -A

# Check ClusterIssuer status
kubectl get clusterissuer vault-issuer -o yaml
```

## What's Next

- [Day-2 Operations](day2-operations.md) — Maintenance, scaling, upgrades
- [Monitoring & Alerts](monitoring-alerts.md) — Using Grafana, alert response
- [Secrets Management](secrets-management.md) — Vault, credential rotation
