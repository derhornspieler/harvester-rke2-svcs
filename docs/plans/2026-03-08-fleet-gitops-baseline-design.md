# Fleet GitOps Baseline Design

**Date**: 2026-03-08
**Status**: Accepted
**Scope**: Convert imperative deploy scripts to declarative Fleet bundles with OCI-first bootstrap

## Context

The `harvester-rke2-svcs` platform deploys six service bundles onto RKE2
clusters using imperative shell scripts (`deploy-*.sh`). These scripts handle
ordering, idempotency, and wiring between services. This design replaces them
with Rancher Fleet for declarative, drift-reconciled deployment.

### Chicken-and-Egg Problem

Fleet typically watches a Git repository, but GitLab (the Git server) is
Bundle 50 — one of the last services deployed. An OCI-first approach resolves
this: Fleet watches OCI artifacts in Harbor (which exists externally before
any cluster services deploy). After GitLab is running, Fleet transitions to a
standard GitRepo-based workflow.

## Architecture

### Two-Phase Lifecycle

**Phase 1 — OCI Bootstrap** (no Git server needed):

```
Developer workstation                    Harbor (external)
  │                                        │
  ├─ push-charts.sh ─────────────────────►│ helm/<chart>   (upstream Helm charts)
  │                                        │
  ├─ push-bundles.sh ────────────────────►│ fleet/<bundle> (fleet bundle OCI artifacts)
  │                                        │
  └─ kubectl apply (Bundle CRs) ──► Rancher/Fleet
                                       │
                                       ├── watches oci://harbor/fleet/00-operators
                                       ├── watches oci://harbor/fleet/05-pki-secrets
                                       ├── watches oci://harbor/fleet/10-identity
                                       ├── watches oci://harbor/fleet/20-monitoring
                                       ├── watches oci://harbor/fleet/30-harbor
                                       ├── watches oci://harbor/fleet/40-gitops
                                       ├── watches oci://harbor/fleet/50-gitlab
                                       └── deploys to rke2-prod
```

**Phase 2 — GitOps steady state** (after GitLab deploys):

1. Push `fleet-gitops/` repo to GitLab
2. Create a `GitRepo` CR pointing at GitLab
3. Delete OCI-based Bundle CRs
4. Fleet reconciles from GitLab (standard GitOps workflow)

### Bundle Ordering and Dependencies

```
00-operators         ← No dependencies (deploys first)
  │
05-pki-secrets       ← dependsOn: 00-operators
  │
10-identity          ← dependsOn: 05-pki-secrets
  │
  ├── 20-monitoring  ← dependsOn: 05-pki-secrets, 10-identity
  ├── 30-harbor      ← dependsOn: 05-pki-secrets, 10-identity
  ├── 40-gitops      ← dependsOn: 05-pki-secrets, 10-identity
  │
50-gitlab            ← dependsOn: 05-pki-secrets, 10-identity, 30-harbor
```

Bundles 20, 30, and 40 deploy in parallel once their dependencies are met.

## Repository Structure

**Location**: `~/code/harvester-rke2-svcs/fleet-gitops/`

```
fleet-gitops/
├── 00-operators/
│   ├── fleet.yaml
│   ├── cnpg-operator/
│   │   ├── fleet.yaml                 # OCI Helm chart
│   │   └── values.yaml
│   ├── redis-operator/
│   │   ├── fleet.yaml                 # OCI Helm chart
│   │   └── values.yaml
│   ├── node-labeler/
│   │   ├── fleet.yaml
│   │   └── manifests/
│   ├── storage-autoscaler/
│   │   ├── fleet.yaml
│   │   └── manifests/
│   └── cluster-autoscaler/
│       ├── fleet.yaml
│       └── manifests/
│
├── 05-pki-secrets/
│   ├── fleet.yaml
│   ├── cert-manager/
│   │   ├── fleet.yaml                 # OCI Helm, self-signed bootstrap issuer
│   │   └── values.yaml
│   ├── vault/
│   │   ├── fleet.yaml                 # OCI Helm, 3-replica HA Raft
│   │   └── values.yaml
│   ├── vault-init/
│   │   ├── fleet.yaml                 # dependsOn: vault
│   │   └── manifests/                 # Job: init, unseal, PKI, K8s auth, KV v2
│   ├── vault-pki-issuer/
│   │   ├── fleet.yaml                 # dependsOn: vault-init
│   │   └── manifests/                 # ClusterIssuer + RBAC for Vault PKI
│   └── external-secrets/
│       ├── fleet.yaml                 # OCI Helm, dependsOn: vault-init
│       └── values.yaml
│
├── 10-identity/
│   ├── fleet.yaml
│   ├── cnpg-keycloak/
│   │   ├── fleet.yaml
│   │   └── manifests/                 # CNPG cluster + own ExternalSecrets
│   ├── keycloak/
│   │   ├── fleet.yaml                 # dependsOn: cnpg-keycloak
│   │   └── manifests/                 # Deployment, HPA, Gateway, HTTPRoute
│   │                                  # Own ExternalSecrets, Vault policies, Certificate CRs
│   └── keycloak-config/
│       ├── fleet.yaml                 # dependsOn: keycloak
│       └── manifests/                 # Job: realm, groups, admin.user super-admin,
│                                      # breakglass user, browser-prompt-login flow
│                                      # (OIDC clients created by consuming services)
│
├── 20-monitoring/
│   ├── fleet.yaml
│   ├── loki/
│   │   ├── fleet.yaml
│   │   └── manifests/
│   ├── alloy/
│   │   ├── fleet.yaml
│   │   └── manifests/
│   ├── kube-prometheus-stack/
│   │   ├── fleet.yaml                 # OCI Helm chart
│   │   └── values.yaml
│   └── ingress-auth/
│       ├── fleet.yaml                 # dependsOn: kube-prometheus-stack
│       └── manifests/                 # Own OAuth2-proxy, OIDC client Job,
│                                      # ExternalSecrets, Certificate CRs,
│                                      # Gateways, HTTPRoutes, ForwardAuth,
│                                      # Dashboards, ServiceMonitors, PrometheusRules
│
├── 30-harbor/
│   ├── fleet.yaml
│   ├── minio/
│   │   ├── fleet.yaml
│   │   └── manifests/                 # Own ExternalSecrets
│   ├── cnpg-harbor/
│   │   ├── fleet.yaml
│   │   └── manifests/                 # Own ExternalSecrets
│   ├── valkey/
│   │   ├── fleet.yaml
│   │   └── manifests/                 # Own ExternalSecrets
│   └── harbor/
│       ├── fleet.yaml                 # OCI Helm, dependsOn: minio, cnpg-harbor, valkey
│       └── values.yaml               # Own OIDC client Job, ExternalSecrets,
│                                      # Vault policies, Certificate CRs, monitoring
│
├── 40-gitops/
│   ├── fleet.yaml
│   ├── argocd/
│   │   ├── fleet.yaml                 # OCI Helm chart
│   │   └── values.yaml               # Own OIDC client Job, ExternalSecrets,
│   │                                  # Vault policies, Certificate CRs, monitoring
│   ├── argo-rollouts/
│   │   ├── fleet.yaml                 # OCI Helm chart
│   │   └── values.yaml               # Own OAuth2-proxy, ExternalSecrets
│   ├── argo-workflows/
│   │   ├── fleet.yaml                 # OCI Helm chart
│   │   └── values.yaml               # Own ExternalSecrets
│   └── analysis-templates/
│       ├── fleet.yaml
│       └── manifests/
│
├── 50-gitlab/
│   ├── fleet.yaml
│   ├── cnpg-gitlab/
│   │   ├── fleet.yaml
│   │   └── manifests/                 # Own ExternalSecrets
│   ├── redis/
│   │   ├── fleet.yaml
│   │   └── manifests/                 # OpsTree Redis + Sentinel, own ExternalSecrets
│   ├── gitlab/
│   │   ├── fleet.yaml                 # OCI Helm, dependsOn: cnpg-gitlab, redis
│   │   └── values.yaml               # Own OIDC client Job, ExternalSecrets,
│   │                                  # Vault policies, Certificate CRs,
│   │                                  # Gateway + HTTPRoute + TCPRoute (SSH), monitoring
│   └── runners/
│       ├── fleet.yaml                 # dependsOn: gitlab
│       └── manifests/                 # 3 runner Helm releases, own RBAC
│
└── scripts/
    ├── push-charts.sh                 # Pull upstream Helm charts, push to Harbor OCI
    └── push-bundles.sh                # Package fleet bundle dirs as OCI, push to Harbor
```

## Self-Contained Service Pattern

Every service bundle (10+) owns all its dependencies internally:

| Concern | Owned By | Mechanism |
|---------|----------|-----------|
| Vault policies/roles | The service | K8s manifests creating Vault K8s auth role + policy |
| Secrets | The service | ExternalSecret CRs referencing own Vault KV paths |
| TLS certificates | The service | Certificate CRs via cert-manager ClusterIssuer |
| OIDC client | The service | Job calling Keycloak Admin API to register its client |
| OAuth2-proxy | The service | Deploys its own instance if it needs auth-protected UI |
| Monitoring | The service | Own ServiceMonitors, PrometheusRules, Grafana dashboards |
| Network policies | The service | Own NetworkPolicy manifests |

### OIDC Client Registration

Each service that needs OIDC creates a Job that:

1. Authenticates to Keycloak Admin API (via ExternalSecret for admin creds)
2. Creates/updates its OIDC client (idempotent)
3. Stores the client secret in Vault KV
4. The service's ExternalSecret syncs the client secret into a K8s Secret

The `keycloak-config` Job (in 10-identity) only creates the realm, groups,
admin users (admin.user as super-admin), and the browser-prompt-login flow.

## Fleet Bundle Types

| Content Type | Packaging | Source |
|-------------|-----------|--------|
| Upstream Helm charts | OCI Helm chart | `oci://harbor.example.com/helm/<chart>` |
| Custom manifests | Raw YAML in Git / OCI bundle | Fleet auto-applies from directory |
| Custom operators | Raw YAML + container images | Manifests in bundle, images in Harbor |
| Helm values | YAML files | Alongside fleet.yaml |

## Cluster Targeting

Each bundle targets `rke2-prod`:

```yaml
targets:
  - clusterName: rke2-prod
```

Multi-cluster: add targets or use `clusterSelector` with labels.

## OCI Artifact Registry Layout

```
harbor.example.com/
├── helm/                              # Upstream Helm charts (OCI)
│   ├── cert-manager:v1.17.2
│   ├── vault:0.29.1
│   ├── external-secrets:0.17.0
│   ├── kube-prometheus-stack:72.3.0
│   ├── harbor:1.17.0
│   ├── argo-cd:7.8.13
│   ├── argo-rollouts:2.39.1
│   ├── argo-workflows:0.45.2
│   └── gitlab:9.0.3
└── fleet/                             # Fleet bundle OCI artifacts
    ├── 00-operators:1.0.0
    ├── 05-pki-secrets:1.0.0
    ├── 10-identity:1.0.0
    ├── 20-monitoring:1.0.0
    ├── 30-harbor:1.0.0
    ├── 40-gitops:1.0.0
    └── 50-gitlab:1.0.0
```

## Migration from Current State

### harvester-rke2-cluster (cluster lifecycle)

1. Archive `.tf` files to `terraform/` subdirectory
2. `rancher-api-deploy.sh` becomes the primary cluster lifecycle tool
3. `prepare.sh` stays for credential refresh
4. Operator deployment moves from `operators.tf` to `fleet-gitops/00-operators/`

### harvester-rke2-svcs (platform services)

1. Existing `services/` and `scripts/` directories remain as reference
2. `fleet-gitops/` is the new declarative source of truth
3. Manifests migrate from `services/` into fleet bundle directories
4. Deploy scripts replaced by `push-bundles.sh` + Fleet reconciliation

## Consequences

**Benefits:**
- Drift reconciliation (Fleet continuously ensures desired state)
- Declarative, version-controlled deployments
- Airgap-native via OCI artifacts in Harbor
- Self-contained services reduce blast radius of changes
- Multi-cluster ready via Fleet targets

**Trade-offs:**
- Vault init/unseal/PKI import still requires imperative Job
- OIDC client registration Jobs add complexity vs central config
- Two operational modes (OCI bootstrap → Git steady state)
- Debugging Fleet bundle failures is less transparent than script output

**Risks:**
- Fleet `dependsOn` ordering must be validated end-to-end
- OCI bundle packaging tooling needs testing (`fleet apply --oci` maturity)
- Root CA key handling during vault-init Job needs secure delivery mechanism
