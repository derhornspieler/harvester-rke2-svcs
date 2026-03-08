# Fleet GitOps Baseline Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Convert imperative deploy scripts into declarative Fleet bundles with OCI-first bootstrap from Harbor.

**Architecture:** Seven ordered Fleet bundles (00-operators through 50-gitlab) deployed via OCI artifacts stored in Harbor. Each service bundle is self-contained: owns its Vault policies, ExternalSecrets, OIDC client registration, OAuth2-proxy, monitoring, and network policies. Existing manifests from `services/` are migrated into fleet bundle directories with `fleet.yaml` wrappers.

**Tech Stack:** Rancher Fleet, OCI Helm charts in Harbor, Vault HA (Raft), cert-manager, ESO, Keycloak OIDC, Gateway API (Traefik), kube-prometheus-stack, CNPG, Redis operators

**Design Doc:** `docs/plans/2026-03-08-fleet-gitops-baseline-design.md`

---

## Key Conventions

- **Existing manifests**: Copy from `services/<svc>/` into `fleet-gitops/<bundle>/<svc>/manifests/`. Do not modify content — only add `fleet.yaml` wrappers.
- **Helm charts**: Reference OCI URLs in Harbor (`oci://harbor.example.com/helm/<chart>`). Values files copied from existing `services/<svc>/*-values.yaml`.
- **Namespaces**: Each service's `namespace.yaml` is included in its manifests directory.
- **fleet.yaml pattern**: Helm bundles use `helm:` block; manifest bundles use `defaultNamespace:` and Fleet auto-discovers YAML.
- **dependsOn**: Uses bundle name labels for ordering within and across groups.
- **Harbor OCI registry**: `harbor.example.com`
- **Domain**: `example.com` (substitute via `CHANGEME_DOMAIN` tokens where needed)

---

## Task 1: Scaffold fleet-gitops directory structure

**Files:**
- Create: `fleet-gitops/` directory tree (empty directories + README)

**Step 1: Create the full directory tree**

```bash
cd ~/code/harvester-rke2-svcs

mkdir -p fleet-gitops/{00-operators/{cnpg-operator,redis-operator,node-labeler/manifests,storage-autoscaler/manifests,cluster-autoscaler/manifests},05-pki-secrets/{cert-manager,vault,vault-init/manifests,vault-pki-issuer/manifests,external-secrets},10-identity/{cnpg-keycloak/manifests,keycloak/manifests,keycloak-config/manifests},20-monitoring/{loki/manifests,alloy/manifests,kube-prometheus-stack,ingress-auth/manifests},30-harbor/{minio/manifests,cnpg-harbor/manifests,valkey/manifests,harbor},40-gitops/{argocd,argo-rollouts/manifests,argo-workflows/manifests,analysis-templates/manifests},50-gitlab/{cnpg-gitlab/manifests,redis/manifests,gitlab,runners/manifests},scripts}
```

**Step 2: Create a README for fleet-gitops**

Create `fleet-gitops/README.md`:
```markdown
# Fleet GitOps Baseline

OCI-first Fleet bundles for the RKE2 platform baseline.

## Bundle Ordering

| Bundle | Services | Depends On |
|--------|----------|------------|
| 00-operators | CNPG, Redis, node-labeler, storage-autoscaler, cluster-autoscaler | None |
| 05-pki-secrets | cert-manager, Vault, ESO | 00-operators |
| 10-identity | Keycloak, keycloak-config | 05-pki-secrets |
| 20-monitoring | Loki, Alloy, kube-prometheus-stack, ingress-auth | 05-pki-secrets, 10-identity |
| 30-harbor | MinIO, CNPG, Valkey, Harbor | 05-pki-secrets, 10-identity |
| 40-gitops | ArgoCD, Argo Rollouts, Argo Workflows | 05-pki-secrets, 10-identity |
| 50-gitlab | CNPG, Redis, GitLab, Runners | 05-pki-secrets, 10-identity, 30-harbor |

## Bootstrap

1. Push Helm charts: `./scripts/push-charts.sh`
2. Push Fleet bundles: `./scripts/push-bundles.sh`
3. Apply Bundle CRs to Rancher: `kubectl apply -f bundle-crs/`
4. After GitLab deploys, switch to GitRepo-based workflow.
```

**Step 3: Commit**

```bash
git add fleet-gitops/
git commit -m "chore: scaffold fleet-gitops directory structure

Seven ordered bundles from operators through GitLab.
See docs/plans/2026-03-08-fleet-gitops-baseline-design.md.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 2: 00-operators — CNPG and Redis operator bundles

**Files:**
- Create: `fleet-gitops/00-operators/fleet.yaml`
- Create: `fleet-gitops/00-operators/cnpg-operator/fleet.yaml`
- Create: `fleet-gitops/00-operators/cnpg-operator/values.yaml`
- Create: `fleet-gitops/00-operators/redis-operator/fleet.yaml`
- Create: `fleet-gitops/00-operators/redis-operator/values.yaml`
- Reference: `services/cnpg-operator/` (HPA, PDB)
- Reference: `services/monitoring-stack/helm/kube-prometheus-stack-values.yaml` (for CRD version context)

**Step 1: Create group fleet.yaml**

`fleet-gitops/00-operators/fleet.yaml`:
```yaml
# 00-operators: CRD operators that must be running before any service bundles
# No dependencies — deploys first
targets:
  - clusterName: rke2-prod
```

**Step 2: Create CNPG operator fleet.yaml**

`fleet-gitops/00-operators/cnpg-operator/fleet.yaml`:
```yaml
defaultNamespace: cnpg-system
helm:
  releaseName: cnpg
  chart: oci://harbor.example.com/helm/cloudnative-pg
  version: "0.27.1"
  valuesFiles:
    - values.yaml
targets:
  - clusterName: rke2-prod
```

**Step 3: Create CNPG values.yaml**

Copy relevant values from existing deployment. Check `services/cnpg-operator/` for HPA/PDB patterns.

`fleet-gitops/00-operators/cnpg-operator/values.yaml`:
```yaml
# CNPG Operator Helm values
crds:
  create: true

config:
  data:
    INHERITED_ANNOTATIONS: "kustomize.toolkit.fluxcd.io/*"
    INHERITED_LABELS: "app.kubernetes.io/*"
```

**Step 4: Create Redis operator fleet.yaml**

`fleet-gitops/00-operators/redis-operator/fleet.yaml`:
```yaml
defaultNamespace: redis-operator
helm:
  releaseName: redis-operator
  chart: oci://harbor.example.com/helm/redis-operator
  version: "0.23.0"
  valuesFiles:
    - values.yaml
targets:
  - clusterName: rke2-prod
```

**Step 5: Create Redis operator values.yaml**

`fleet-gitops/00-operators/redis-operator/values.yaml`:
```yaml
# Redis Operator (Spotahome) Helm values
# Minimal — defaults are sane
```

**Step 6: Commit**

```bash
git add fleet-gitops/00-operators/
git commit -m "feat(fleet): add 00-operators bundle — CNPG and Redis operator

OCI Helm charts from Harbor. CRD operators deploy first,
before any service bundles that depend on their CRDs.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 3: 00-operators — Custom operators (node-labeler, storage-autoscaler, cluster-autoscaler)

**Files:**
- Copy from: `~/code/harvester-rke2-cluster/operators/manifests/node-labeler/`
- Copy from: `~/code/harvester-rke2-cluster/operators/manifests/storage-autoscaler/`
- Copy from: `~/code/harvester-rke2-cluster/operators/manifests/cluster-autoscaler/`
- Copy from: `~/code/harvester-rke2-cluster/operators/templates/*.yaml.tftpl` (render to static YAML)
- Create: fleet.yaml for each operator

**Step 1: Copy node-labeler manifests**

```bash
cp ~/code/harvester-rke2-cluster/operators/manifests/node-labeler/*.yaml \
   fleet-gitops/00-operators/node-labeler/manifests/
```

**Step 2: Render node-labeler deployment template to static YAML**

The template at `operators/templates/node-labeler-deployment.yaml.tftpl` contains `${harbor_fqdn}` and `${version}` placeholders. Render with actual values:

```bash
sed -e 's/${harbor_fqdn}/harbor.example.com/g' \
    -e 's/${version}/v0.2.0/g' \
    ~/code/harvester-rke2-cluster/operators/templates/node-labeler-deployment.yaml.tftpl \
    > fleet-gitops/00-operators/node-labeler/manifests/deployment.yaml
```

**Step 3: Create node-labeler fleet.yaml**

`fleet-gitops/00-operators/node-labeler/fleet.yaml`:
```yaml
defaultNamespace: node-labeler
targets:
  - clusterName: rke2-prod
```

**Step 4: Repeat for storage-autoscaler**

```bash
cp ~/code/harvester-rke2-cluster/operators/manifests/storage-autoscaler/*.yaml \
   fleet-gitops/00-operators/storage-autoscaler/manifests/

sed -e 's/${harbor_fqdn}/harbor.example.com/g' \
    -e 's/${version}/v0.2.0/g' \
    ~/code/harvester-rke2-cluster/operators/templates/storage-autoscaler-deployment.yaml.tftpl \
    > fleet-gitops/00-operators/storage-autoscaler/manifests/deployment.yaml
```

`fleet-gitops/00-operators/storage-autoscaler/fleet.yaml`:
```yaml
defaultNamespace: storage-autoscaler
targets:
  - clusterName: rke2-prod
```

**Step 5: Repeat for cluster-autoscaler**

```bash
cp ~/code/harvester-rke2-cluster/operators/manifests/cluster-autoscaler/*.yaml \
   fleet-gitops/00-operators/cluster-autoscaler/manifests/

sed -e 's/${harbor_fqdn}/harbor.example.com/g' \
    -e 's/${version}/v1.34.3/g' \
    ~/code/harvester-rke2-cluster/operators/templates/cluster-autoscaler-deployment.yaml.tftpl \
    > fleet-gitops/00-operators/cluster-autoscaler/manifests/deployment.yaml
```

`fleet-gitops/00-operators/cluster-autoscaler/fleet.yaml`:
```yaml
defaultNamespace: cluster-autoscaler
targets:
  - clusterName: rke2-prod
```

**Step 6: Commit**

```bash
git add fleet-gitops/00-operators/
git commit -m "feat(fleet): add custom operators to 00-operators bundle

Migrate node-labeler, storage-autoscaler, cluster-autoscaler from
harvester-rke2-cluster operators.tf. Templates rendered to static YAML
with Harbor FQDN and version baked in.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 4: 05-pki-secrets — cert-manager bundle

**Files:**
- Create: `fleet-gitops/05-pki-secrets/fleet.yaml`
- Create: `fleet-gitops/05-pki-secrets/cert-manager/fleet.yaml`
- Create: `fleet-gitops/05-pki-secrets/cert-manager/values.yaml`
- Reference: `services/cert-manager/` (MANIFEST.yaml, namespace.yaml, rbac.yaml)

**Step 1: Create group fleet.yaml with dependency on operators**

`fleet-gitops/05-pki-secrets/fleet.yaml`:
```yaml
# 05-pki-secrets: cert-manager, Vault, ESO
# Must wait for 00-operators (CNPG CRDs needed by Vault init)
dependsOn:
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: 00-operators
targets:
  - clusterName: rke2-prod
```

**Step 2: Create cert-manager fleet.yaml**

`fleet-gitops/05-pki-secrets/cert-manager/fleet.yaml`:
```yaml
defaultNamespace: cert-manager
helm:
  releaseName: cert-manager
  chart: oci://harbor.example.com/helm/cert-manager
  version: "v1.19.4"
  valuesFiles:
    - values.yaml
targets:
  - clusterName: rke2-prod
```

**Step 3: Create cert-manager values.yaml**

Reference the inline `--set` flags from `deploy-pki-secrets.sh` phase 1:

`fleet-gitops/05-pki-secrets/cert-manager/values.yaml`:
```yaml
crds:
  enabled: true

# Gateway API shim for Certificate resources
extraArgs:
  - --enable-gateway-api

# Prometheus ServiceMonitor
prometheus:
  enabled: true
  servicemonitor:
    enabled: true
```

**Step 4: Commit**

```bash
git add fleet-gitops/05-pki-secrets/
git commit -m "feat(fleet): add cert-manager to 05-pki-secrets bundle

OCI Helm chart from Harbor with CRDs and Gateway API shim.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 5: 05-pki-secrets — Vault bundle

**Files:**
- Create: `fleet-gitops/05-pki-secrets/vault/fleet.yaml`
- Copy: `services/vault/vault-values.yaml` → `fleet-gitops/05-pki-secrets/vault/values.yaml`
- Reference: `services/vault/MANIFEST.yaml`

**Step 1: Create Vault fleet.yaml**

`fleet-gitops/05-pki-secrets/vault/fleet.yaml`:
```yaml
defaultNamespace: vault
helm:
  releaseName: vault
  chart: oci://harbor.example.com/helm/vault
  version: "0.32.0"
  valuesFiles:
    - values.yaml
targets:
  - clusterName: rke2-prod
```

**Step 2: Copy Vault values**

```bash
cp services/vault/vault-values.yaml fleet-gitops/05-pki-secrets/vault/values.yaml
```

**Step 3: Commit**

```bash
git add fleet-gitops/05-pki-secrets/vault/
git commit -m "feat(fleet): add Vault to 05-pki-secrets bundle

3-replica HA Raft on database pool nodes. OCI Helm chart from Harbor.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 6: 05-pki-secrets — vault-init Job bundle

**Files:**
- Create: `fleet-gitops/05-pki-secrets/vault-init/fleet.yaml`
- Create: `fleet-gitops/05-pki-secrets/vault-init/manifests/vault-init-job.yaml`
- Reference: `scripts/utils/vault.sh` (for init/unseal/PKI logic)
- Reference: `scripts/deploy-pki-secrets.sh` phases 2-4

**Step 1: Create vault-init fleet.yaml with dependency on vault**

`fleet-gitops/05-pki-secrets/vault-init/fleet.yaml`:
```yaml
defaultNamespace: vault
dependsOn:
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: vault
targets:
  - clusterName: rke2-prod
```

**Step 2: Create vault-init Job manifest**

This Job encapsulates phases 2-4 from `deploy-pki-secrets.sh`: Vault init, unseal, Raft join, PKI import, K8s auth, KV v2 enable.

`fleet-gitops/05-pki-secrets/vault-init/manifests/vault-init-job.yaml`:

This is the most complex manifest — it must encode the imperative init/unseal/PKI logic from `scripts/utils/vault.sh` and `deploy-pki-secrets.sh` phases 2-4 as a Kubernetes Job. The Job:

1. Waits for vault-0 to be running
2. Checks if Vault is already initialized (idempotent)
3. If not: initializes with 5 Shamir keys, stores init output in a K8s Secret
4. Unseals all 3 replicas (using keys from the Secret)
5. Joins vault-1 and vault-2 to Raft cluster
6. Enables PKI secrets engine
7. Imports Root CA (from a pre-seeded K8s Secret containing the PEM)
8. Generates intermediate CSR, signs with Root CA key (from Secret), imports chain
9. Enables Kubernetes auth method
10. Creates cert-manager-issuer role and PKI policy
11. Enables KV v2 engine

**Note:** This Job requires the Root CA key to be pre-seeded as a K8s Secret before Fleet deploys this bundle. This is the one manual prerequisite.

Create the Job manifest based on the logic in `scripts/utils/vault.sh`. The implementation engineer should read:
- `scripts/utils/vault.sh` (all functions)
- `scripts/deploy-pki-secrets.sh` phases 2, 3, 4
- `services/cert-manager/rbac.yaml` (for the ServiceAccount the Job needs)

**Step 3: Commit**

```bash
git add fleet-gitops/05-pki-secrets/vault-init/
git commit -m "feat(fleet): add vault-init Job to 05-pki-secrets

Encapsulates Vault init, unseal, Raft join, PKI import, K8s auth
as a K8s Job. Requires Root CA key pre-seeded as K8s Secret.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 7: 05-pki-secrets — vault-pki-issuer and external-secrets bundles

**Files:**
- Create: `fleet-gitops/05-pki-secrets/vault-pki-issuer/fleet.yaml`
- Copy: `services/cert-manager/rbac.yaml`, `services/cert-manager/cluster-issuer.yaml` → manifests/
- Create: `fleet-gitops/05-pki-secrets/external-secrets/fleet.yaml`
- Create: `fleet-gitops/05-pki-secrets/external-secrets/values.yaml`
- Reference: `services/external-secrets/MANIFEST.yaml`

**Step 1: Create vault-pki-issuer fleet.yaml**

`fleet-gitops/05-pki-secrets/vault-pki-issuer/fleet.yaml`:
```yaml
defaultNamespace: cert-manager
dependsOn:
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: vault-init
targets:
  - clusterName: rke2-prod
```

**Step 2: Copy ClusterIssuer and RBAC manifests**

```bash
cp services/cert-manager/rbac.yaml \
   services/cert-manager/cluster-issuer.yaml \
   fleet-gitops/05-pki-secrets/vault-pki-issuer/manifests/
```

**Step 3: Create ESO fleet.yaml**

`fleet-gitops/05-pki-secrets/external-secrets/fleet.yaml`:
```yaml
defaultNamespace: external-secrets
helm:
  releaseName: external-secrets
  chart: oci://harbor.example.com/helm/external-secrets
  version: "2.0.1"
  valuesFiles:
    - values.yaml
dependsOn:
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: vault-init
targets:
  - clusterName: rke2-prod
```

**Step 4: Create ESO values.yaml**

`fleet-gitops/05-pki-secrets/external-secrets/values.yaml`:
```yaml
crds:
  createClusterExternalSecret: true
  createClusterSecretStore: true
  createPushSecret: true

serviceMonitor:
  enabled: true
```

**Step 5: Commit**

```bash
git add fleet-gitops/05-pki-secrets/
git commit -m "feat(fleet): add vault-pki-issuer and ESO to 05-pki-secrets

ClusterIssuer for Vault PKI + ESO Helm chart. Both depend on
vault-init completing successfully.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 8: 10-identity — Keycloak bundle (self-contained)

**Files:**
- Create: `fleet-gitops/10-identity/fleet.yaml`
- Create: fleet.yaml + copy manifests for cnpg-keycloak, keycloak, keycloak-config
- Reference: `services/keycloak/` (all subdirectories)
- Reference: `scripts/deploy-keycloak.sh`, `scripts/setup-keycloak.sh`

**Step 1: Create group fleet.yaml**

`fleet-gitops/10-identity/fleet.yaml`:
```yaml
dependsOn:
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: 05-pki-secrets
targets:
  - clusterName: rke2-prod
```

**Step 2: Create cnpg-keycloak bundle**

`fleet-gitops/10-identity/cnpg-keycloak/fleet.yaml`:
```yaml
defaultNamespace: database
targets:
  - clusterName: rke2-prod
```

Copy CNPG cluster manifests + ExternalSecrets:
```bash
cp services/keycloak/postgres/*.yaml \
   fleet-gitops/10-identity/cnpg-keycloak/manifests/
```

**Step 3: Create keycloak bundle**

`fleet-gitops/10-identity/keycloak/fleet.yaml`:
```yaml
defaultNamespace: keycloak
dependsOn:
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: cnpg-keycloak
targets:
  - clusterName: rke2-prod
```

Copy all keycloak manifests (deployment, services, HPA, Gateway, HTTPRoute, ExternalSecrets, Certificate CRs, Vault policies, monitoring):
```bash
cp services/keycloak/keycloak/*.yaml \
   fleet-gitops/10-identity/keycloak/manifests/
# Also copy monitoring, gateway, ExternalSecrets from relevant subdirs
```

**Step 4: Create keycloak-config bundle**

`fleet-gitops/10-identity/keycloak-config/fleet.yaml`:
```yaml
defaultNamespace: keycloak
dependsOn:
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: keycloak
targets:
  - clusterName: rke2-prod
```

Create a Job manifest that encapsulates `scripts/setup-keycloak.sh` phases 1-5:
- Create `platform` realm
- Create `admin-breakglass` user
- Create `platform-admins` group
- Add `admin.user` as super-admin
- Configure `browser-prompt-login` auth flow

Place in `fleet-gitops/10-identity/keycloak-config/manifests/keycloak-config-job.yaml`.

The implementation engineer should read `scripts/setup-keycloak.sh` to understand each Keycloak Admin API call that needs to be encoded in the Job.

**Step 5: Commit**

```bash
git add fleet-gitops/10-identity/
git commit -m "feat(fleet): add 10-identity bundle — Keycloak + config

Self-contained: CNPG PostgreSQL, Keycloak deployment, realm/group
config Job. Owns its ExternalSecrets, Vault policies, and Certificate CRs.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 9: 20-monitoring — Monitoring stack bundle (self-contained)

**Files:**
- Create: fleet.yaml files for loki, alloy, kube-prometheus-stack, ingress-auth
- Copy: manifests from `services/monitoring-stack/`
- Reference: `scripts/deploy-monitoring.sh`

**Step 1: Create group fleet.yaml**

`fleet-gitops/20-monitoring/fleet.yaml`:
```yaml
dependsOn:
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: 05-pki-secrets
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: 10-identity
targets:
  - clusterName: rke2-prod
```

**Step 2: Create Loki and Alloy bundles**

Copy manifests from `services/monitoring-stack/loki/` and `services/monitoring-stack/alloy/`:
```bash
cp services/monitoring-stack/loki/*.yaml fleet-gitops/20-monitoring/loki/manifests/
cp services/monitoring-stack/alloy/*.yaml fleet-gitops/20-monitoring/alloy/manifests/
```

Create fleet.yaml for each with `defaultNamespace: monitoring-stack`.

**Step 3: Create kube-prometheus-stack bundle**

`fleet-gitops/20-monitoring/kube-prometheus-stack/fleet.yaml`:
```yaml
defaultNamespace: monitoring-stack
helm:
  releaseName: kube-prometheus-stack
  chart: oci://harbor.example.com/helm/kube-prometheus-stack
  version: "82.10.0"
  valuesFiles:
    - values.yaml
targets:
  - clusterName: rke2-prod
```

```bash
cp services/monitoring-stack/helm/kube-prometheus-stack-values.yaml \
   fleet-gitops/20-monitoring/kube-prometheus-stack/values.yaml
```

**Step 4: Create ingress-auth bundle (self-contained OAuth2-proxy + OIDC)**

`fleet-gitops/20-monitoring/ingress-auth/fleet.yaml`:
```yaml
defaultNamespace: monitoring-stack
dependsOn:
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: kube-prometheus-stack
targets:
  - clusterName: rke2-prod
```

Copy manifests for:
- OAuth2-proxy instances (Prometheus, Grafana, Alertmanager) from `services/keycloak/oauth2-proxy/`
- OIDC client registration Job (create clients for monitoring services in Keycloak)
- ExternalSecrets for OIDC client secrets and basic-auth
- Vault policies/roles for monitoring
- Certificate CRs for monitoring endpoints
- Gateways, HTTPRoutes, ForwardAuth middleware
- All dashboards from `services/monitoring-stack/grafana/dashboards/`
- ServiceMonitors and PrometheusRules from `services/monitoring-stack/`

**Step 5: Commit**

```bash
git add fleet-gitops/20-monitoring/
git commit -m "feat(fleet): add 20-monitoring bundle — Prometheus, Grafana, Loki

Self-contained: owns OAuth2-proxy, OIDC client registration,
ExternalSecrets, monitoring dashboards, and Gateway ingress.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 10: 30-harbor — Harbor bundle (self-contained)

**Files:**
- Create: fleet.yaml files for minio, cnpg-harbor, valkey, harbor
- Copy: manifests from `services/harbor/`
- Reference: `scripts/deploy-harbor.sh`

**Step 1: Create group fleet.yaml**

`fleet-gitops/30-harbor/fleet.yaml`:
```yaml
dependsOn:
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: 05-pki-secrets
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: 10-identity
targets:
  - clusterName: rke2-prod
```

**Step 2: Create MinIO, CNPG, Valkey sub-bundles**

Each with their own fleet.yaml and manifests copied from `services/harbor/`:
```bash
cp services/harbor/minio/*.yaml fleet-gitops/30-harbor/minio/manifests/
cp services/harbor/postgres/*.yaml fleet-gitops/30-harbor/cnpg-harbor/manifests/
cp services/harbor/valkey/*.yaml fleet-gitops/30-harbor/valkey/manifests/
```

Each sub-bundle owns its ExternalSecrets (MinIO creds, DB password, Redis password).

**Step 3: Create Harbor Helm bundle**

`fleet-gitops/30-harbor/harbor/fleet.yaml`:
```yaml
defaultNamespace: harbor
helm:
  releaseName: harbor
  chart: oci://harbor.example.com/helm/harbor
  version: "1.18.2"
  valuesFiles:
    - values.yaml
dependsOn:
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: minio
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: cnpg-harbor
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: valkey
targets:
  - clusterName: rke2-prod
```

Copy Harbor values and add self-contained resources:
- OIDC client registration Job for Keycloak
- ExternalSecrets (Harbor admin, S3, TLS)
- Vault policies/roles
- Certificate CRs
- Gateway + HTTPRoute
- HPA manifests
- Monitoring (dashboards, alerts, ServiceMonitors)

**Step 4: Commit**

```bash
git add fleet-gitops/30-harbor/
git commit -m "feat(fleet): add 30-harbor bundle — Harbor + MinIO + CNPG + Valkey

Self-contained: owns OIDC client, ExternalSecrets, Vault policies,
TLS certificates, and monitoring for all Harbor components.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 11: 40-gitops — ArgoCD, Rollouts, Workflows bundle (self-contained)

**Files:**
- Create: fleet.yaml files for argocd, argo-rollouts, argo-workflows, analysis-templates
- Copy: manifests and values from `services/argo/`
- Reference: `scripts/deploy-argo.sh`

**Step 1: Create group fleet.yaml**

`fleet-gitops/40-gitops/fleet.yaml`:
```yaml
dependsOn:
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: 05-pki-secrets
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: 10-identity
targets:
  - clusterName: rke2-prod
```

**Step 2: Create ArgoCD Helm bundle**

`fleet-gitops/40-gitops/argocd/fleet.yaml`:
```yaml
defaultNamespace: argocd
helm:
  releaseName: argocd
  chart: oci://harbor.example.com/helm/argo-cd
  version: "9.4.7"
  valuesFiles:
    - values.yaml
targets:
  - clusterName: rke2-prod
```

```bash
cp services/argo/argocd/argocd-values.yaml fleet-gitops/40-gitops/argocd/values.yaml
```

Self-contained resources in argocd manifests:
- OIDC client registration Job (Keycloak)
- ExternalSecrets (OIDC secret, admin password)
- Vault policies/roles
- Certificate CRs
- Gateway + HTTPRoute
- Monitoring

**Step 3: Create Argo Rollouts and Workflows bundles**

Copy from `services/argo/argo-rollouts/` and `services/argo/argo-workflows/`:
- Helm values
- OAuth2-proxy manifests (self-contained)
- ExternalSecrets for basic-auth / OIDC
- Gateway + HTTPRoute manifests

**Step 4: Create analysis-templates bundle**

```bash
cp services/argo/analysis-templates/*.yaml \
   fleet-gitops/40-gitops/analysis-templates/manifests/
```

`fleet-gitops/40-gitops/analysis-templates/fleet.yaml`:
```yaml
# ClusterAnalysisTemplates are cluster-scoped
targets:
  - clusterName: rke2-prod
```

**Step 5: Commit**

```bash
git add fleet-gitops/40-gitops/
git commit -m "feat(fleet): add 40-gitops bundle — ArgoCD, Rollouts, Workflows

Self-contained: each Argo component owns its OIDC client,
OAuth2-proxy, ExternalSecrets, and monitoring.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 12: 50-gitlab — GitLab bundle (self-contained)

**Files:**
- Create: fleet.yaml files for cnpg-gitlab, redis, gitlab, runners
- Copy: manifests and values from `services/gitlab/`
- Reference: `scripts/deploy-gitlab.sh`

**Step 1: Create group fleet.yaml**

`fleet-gitops/50-gitlab/fleet.yaml`:
```yaml
dependsOn:
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: 05-pki-secrets
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: 10-identity
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: 30-harbor
targets:
  - clusterName: rke2-prod
```

**Step 2: Create CNPG and Redis sub-bundles**

```bash
cp services/gitlab/postgres/*.yaml fleet-gitops/50-gitlab/cnpg-gitlab/manifests/
cp services/gitlab/redis/*.yaml fleet-gitops/50-gitlab/redis/manifests/
```

Each owns its ExternalSecrets.

**Step 3: Create GitLab Helm bundle**

`fleet-gitops/50-gitlab/gitlab/fleet.yaml`:
```yaml
defaultNamespace: gitlab
helm:
  releaseName: gitlab
  chart: oci://harbor.example.com/helm/gitlab
  version: "9.9.2"
  valuesFiles:
    - values.yaml
dependsOn:
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: cnpg-gitlab
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: redis-gitlab
targets:
  - clusterName: rke2-prod
```

Self-contained resources:
- OIDC client registration Job (Keycloak)
- ExternalSecrets (root pw, Gitaly token, Praefect secret, OIDC, Harbor push creds)
- Vault policies/roles
- Certificate CRs
- Gateway + HTTPRoute + TCPRoute (SSH port 22)
- Volume autoscalers
- Monitoring

**Step 4: Create runners bundle**

`fleet-gitops/50-gitlab/runners/fleet.yaml`:
```yaml
defaultNamespace: gitlab-runners
dependsOn:
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: gitlab
targets:
  - clusterName: rke2-prod
```

Copy runner Helm values and RBAC from `services/gitlab/runners/`.

**Step 5: Commit**

```bash
git add fleet-gitops/50-gitlab/
git commit -m "feat(fleet): add 50-gitlab bundle — GitLab + Redis + CNPG + Runners

Self-contained: owns OIDC client, ExternalSecrets, Vault policies,
SSH TCPRoute, and monitoring. Runners deploy after GitLab is ready.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 13: scripts/push-charts.sh — OCI Helm chart pipeline

**Files:**
- Create: `fleet-gitops/scripts/push-charts.sh`

**Step 1: Create push-charts.sh**

`fleet-gitops/scripts/push-charts.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

# push-charts.sh — Pull upstream Helm charts and push to Harbor OCI registry
#
# Usage: ./push-charts.sh
#
# Prerequisites: helm CLI, Harbor credentials (helm registry login)

HARBOR="harbor.example.com"

CHARTS=(
  # chart-name|repo-url|version
  "cert-manager|https://charts.jetstack.io|v1.19.4"
  "vault|https://helm.releases.hashicorp.com|0.32.0"
  "external-secrets|https://charts.external-secrets.io|2.0.1"
  "cloudnative-pg|https://cloudnative-pg.github.io/charts|0.27.1"
  "kube-prometheus-stack|https://prometheus-community.github.io/helm-charts|82.10.0"
  "harbor|https://helm.goharbor.io|1.18.2"
  "gitlab|https://charts.gitlab.io|9.9.2"
  "gitlab-runner|https://charts.gitlab.io|0.86.0"
)

# OCI charts (already OCI, just re-tag to Harbor)
OCI_CHARTS=(
  # chart-name|oci-source|version
  "argo-cd|oci://ghcr.io/argoproj/argo-helm/argo-cd|9.4.7"
  "argo-rollouts|oci://ghcr.io/argoproj/argo-helm/argo-rollouts|2.40.6"
  "argo-workflows|oci://ghcr.io/argoproj/argo-helm/argo-workflows|0.47.4"
)

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Repo-based charts: add repo, pull, push
for entry in "${CHARTS[@]}"; do
  IFS='|' read -r name repo version <<< "${entry}"
  log "Processing ${name}:${version}..."
  helm repo add "${name%%/*}" "${repo}" --force-update 2>/dev/null || true
  helm repo update "${name%%/*}" 2>/dev/null || true
  helm pull "${name}" --repo "${repo}" --version "${version}"
  helm push "${name}-${version}.tgz" "oci://${HARBOR}/helm/"
  rm -f "${name}-${version}.tgz"
  log "  Pushed oci://${HARBOR}/helm/${name}:${version}"
done

# OCI charts: pull from source, push to Harbor
for entry in "${OCI_CHARTS[@]}"; do
  IFS='|' read -r name source version <<< "${entry}"
  log "Processing ${name}:${version} (OCI)..."
  helm pull "${source}" --version "${version}"
  helm push "${name}-${version}.tgz" "oci://${HARBOR}/helm/"
  rm -f "${name}-${version}.tgz"
  log "  Pushed oci://${HARBOR}/helm/${name}:${version}"
done

log "All charts pushed to oci://${HARBOR}/helm/"
```

**Step 2: Make executable and commit**

```bash
chmod +x fleet-gitops/scripts/push-charts.sh
git add fleet-gitops/scripts/push-charts.sh
git commit -m "feat(fleet): add push-charts.sh for OCI Helm chart pipeline

Pulls upstream charts and pushes to Harbor OCI registry.
Handles both repo-based and OCI-source charts.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 14: scripts/push-bundles.sh — OCI Fleet bundle pipeline

**Files:**
- Create: `fleet-gitops/scripts/push-bundles.sh`

**Step 1: Create push-bundles.sh**

This script packages each fleet bundle directory as an OCI artifact and pushes to Harbor. Fleet can then watch these OCI artifacts.

`fleet-gitops/scripts/push-bundles.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

# push-bundles.sh — Package Fleet bundle directories as OCI artifacts
#                    and push to Harbor for OCI-first bootstrap
#
# Usage: ./push-bundles.sh [--version 1.0.0]
#
# Prerequisites: helm CLI, oras CLI (for OCI push), Harbor credentials

HARBOR="harbor.example.com"
VERSION="${1:-1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_DIR="$(dirname "${SCRIPT_DIR}")"

BUNDLES=(
  "00-operators"
  "05-pki-secrets"
  "10-identity"
  "20-monitoring"
  "30-harbor"
  "40-gitops"
  "50-gitlab"
)

log() { echo "[$(date +%H:%M:%S)] $*"; }

for bundle in "${BUNDLES[@]}"; do
  bundle_dir="${FLEET_DIR}/${bundle}"
  if [[ ! -d "${bundle_dir}" ]]; then
    log "SKIP ${bundle} (directory not found)"
    continue
  fi

  log "Packaging ${bundle}:${VERSION}..."

  # Create a temporary Helm chart wrapper for the bundle
  tmpdir=$(mktemp -d)
  trap 'rm -rf "${tmpdir}"' EXIT

  # Chart.yaml
  cat > "${tmpdir}/Chart.yaml" <<EOF
apiVersion: v2
name: ${bundle}
version: ${VERSION}
description: Fleet bundle ${bundle}
type: application
EOF

  # Copy bundle contents as templates
  mkdir -p "${tmpdir}/templates"
  find "${bundle_dir}" -name "*.yaml" -o -name "*.yml" | while read -r f; do
    rel="${f#"${bundle_dir}/"}"
    target_dir="${tmpdir}/templates/$(dirname "${rel}")"
    mkdir -p "${target_dir}"
    cp "${f}" "${target_dir}/"
  done

  # Package and push
  helm package "${tmpdir}" -d "${tmpdir}"
  helm push "${tmpdir}/${bundle}-${VERSION}.tgz" "oci://${HARBOR}/fleet/"
  log "  Pushed oci://${HARBOR}/fleet/${bundle}:${VERSION}"

  rm -rf "${tmpdir}"
  trap - EXIT
done

log "All bundles pushed to oci://${HARBOR}/fleet/"
```

**Step 2: Make executable and commit**

```bash
chmod +x fleet-gitops/scripts/push-bundles.sh
git add fleet-gitops/scripts/push-bundles.sh
git commit -m "feat(fleet): add push-bundles.sh for OCI bundle packaging

Packages fleet bundle directories as Helm chart OCI artifacts
and pushes to Harbor. Used for OCI-first bootstrap before GitLab.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 15: Archive Terraform files in harvester-rke2-cluster

**Files:**
- Move: all `.tf` files in `~/code/harvester-rke2-cluster/` → `terraform/` subdirectory
- Keep at root: `rancher-api-deploy.sh`, `prepare.sh`, `terraform.tfvars`, kubeconfigs

**Step 1: Create terraform directory and move files**

```bash
cd ~/code/harvester-rke2-cluster
mkdir -p terraform
mv *.tf terraform/
mv .terraform* terraform/ 2>/dev/null || true
mv terraform.sh terraform/
```

**Step 2: Keep config and deploy files at root**

Verify these stay at root:
- `rancher-api-deploy.sh`
- `prepare.sh`
- `terraform.tfvars` (still used by rancher-api-deploy.sh)
- `kubeconfig-harvester.yaml`
- `kubeconfig-harvester-cloud-cred.yaml`
- `harvester-cloud-provider-kubeconfig`

**Step 3: Commit**

```bash
git add -A
git commit -m "refactor: archive Terraform files to terraform/ subdirectory

rancher-api-deploy.sh is now the primary cluster lifecycle tool.
Terraform files preserved for reference but no longer actively used.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

## Task 16: Update agent memory with Fleet decisions

**Files:**
- Modify: `~/code/harvester-rke2-cluster/.claude/agent-memory-local/k8s-infra-engineer/MEMORY.md`
- Modify: `~/code/harvester-rke2-svcs/.claude/agent-memory-local/platform-engineer/MEMORY.md` (if exists)

**Step 1: Update k8s-infra-engineer memory**

Add section:
```markdown
### Fleet GitOps Baseline
- Platform services migrated from imperative scripts to Fleet bundles
- OCI-first bootstrap: bundles packaged as OCI artifacts in Harbor (no Git needed)
- Seven ordered bundles: 00-operators → 05-pki-secrets → 10-identity → 20/30/40 parallel → 50-gitlab
- Self-contained services: each bundle owns its Vault policies, ExternalSecrets, OIDC client, OAuth2-proxy, monitoring
- Terraform archived to terraform/ subdirectory, rancher-api-deploy.sh is primary
- Fleet repo: ~/code/harvester-rke2-svcs/fleet-gitops/
- Design doc: docs/plans/2026-03-08-fleet-gitops-baseline-design.md
```

**Step 2: Update platform-engineer memory**

Add Fleet GitOps section covering the bundle structure, OCI pipeline, and self-contained service pattern.

**Step 3: Commit memory updates**

---

## Execution Order Summary

| Task | Component | Type | Estimated Steps |
|------|-----------|------|----------------|
| 1 | Directory scaffold + README | Structure | 3 |
| 2 | 00-operators (CNPG + Redis Helm) | Helm bundles | 6 |
| 3 | 00-operators (custom operators) | Manifest copy + render | 6 |
| 4 | 05-pki-secrets (cert-manager) | Helm bundle | 4 |
| 5 | 05-pki-secrets (Vault) | Helm bundle | 3 |
| 6 | 05-pki-secrets (vault-init Job) | Complex manifest | 3 |
| 7 | 05-pki-secrets (issuer + ESO) | Mixed | 5 |
| 8 | 10-identity (Keycloak) | Manifest + Job | 5 |
| 9 | 20-monitoring (full stack) | Helm + manifests | 5 |
| 10 | 30-harbor (full stack) | Helm + manifests | 4 |
| 11 | 40-gitops (Argo stack) | Helm + manifests | 5 |
| 12 | 50-gitlab (full stack) | Helm + manifests | 5 |
| 13 | push-charts.sh | Script | 2 |
| 14 | push-bundles.sh | Script | 2 |
| 15 | Archive Terraform | Repo cleanup | 3 |
| 16 | Update agent memory | Documentation | 3 |

**Total: 16 tasks, ~64 steps**

Tasks 2-12 can be partially parallelized (tasks within a bundle are sequential, but independent bundles can be worked on concurrently).
