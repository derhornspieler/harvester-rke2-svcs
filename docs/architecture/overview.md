# Platform Overview

## Executive Summary

This platform delivers a production-grade GitOps foundation on a 13-node Harvester RKE2 cluster, providing secure, observable, self-healing infrastructure for containerized workloads. It combines identity management (Keycloak + OAuth2-proxy), container registry (Harbor), policy-driven deployments (ArgoCD), and Git-native CI/CD (GitLab + Runners), all protected by zero-trust PKI and automated secrets management. Integrated monitoring (Prometheus, Grafana, Loki) and audit trails provide visibility across all ecosystems.

---

## Platform at a Glance

The platform is organized into 7 ecosystem groups deployed as 65 bundles across 9 bundle groups with strict dependency ordering. Every service is production-ready with HA, autoscaling, observability, and zero-trust security.

```mermaid
block-beta
    columns 3

    block:security["🔒 Security &amp; PKI"]:2
        RootCA["Offline Root CA"]
        Vault["Vault HA<br/>(Secrets + Intermediate CA)"]
        CertMgr["cert-manager<br/>(Auto TLS)"]
        ESO["External Secrets<br/>Operator"]
    end

    block:identity["🔐 Identity &amp; Access"]
        KC["Keycloak<br/>(OIDC Provider)"]
        OAuth["OAuth2-proxy<br/>(Auth Gateway)"]
    end

    block:monitoring["📊 Observability"]:2
        Prom["Prometheus<br/>(Metrics)"]
        Graf["Grafana<br/>(Dashboards)"]
        Loki["Loki<br/>(Logs)"]
        Alloy["Alloy<br/>(Collector)"]
        Hubble["Hubble<br/>(Network Flows)"]
        AM["Alertmanager<br/>(Alerts)"]
    end

    block:platform["🚀 Platform"]
        ArgoCD["ArgoCD<br/>(GitOps Deploy)"]
        Rollouts["Argo Rollouts<br/>(Canary/Blue-Green)"]
        Workflows["Argo Workflows<br/>(Automation)"]
    end

    block:cicd["💻 CI/CD"]:2
        GitLab["GitLab EE<br/>(Source + Pipelines)"]
        Runners["GitLab Runners<br/>(Job Execution)"]
        Harbor["Harbor<br/>(Container Registry)"]
    end

    block:data["💾 Data &amp; Storage"]
        CNPG["PostgreSQL HA<br/>(3 Clusters)"]
        Redis["Redis Sentinel<br/>(Cache)"]
        MinIO["MinIO<br/>(Object Storage)"]
        BackupMinIO["Backup MinIO<br/>(Cross-Cluster Backups)"]
    end

    style security fill:#dc3545,color:#fff
    style identity fill:#6f42c1,color:#fff
    style monitoring fill:#fd7e14,color:#fff
    style platform fill:#198754,color:#fff
    style cicd fill:#0d6efd,color:#fff
    style data fill:#0dcaf0,color:#000
```

### How the Stacks Relate

| Stack | Depends On | Provides To |
|-------|-----------|-------------|
| Security &amp; PKI | — (foundation) | TLS certificates and secrets to all stacks |
| Identity &amp; Access | Security (certs, secrets); optionally FreeIPA (LDAP) | Single sign-on to Platform, CI/CD, Observability |
| Observability | Security, Identity | Metrics, logs, alerts for all stacks |
| Data &amp; Storage | Security (secrets) | PostgreSQL, Redis, MinIO for Platform and CI/CD |
| Platform | Security, Identity, Data | GitOps deployment for all applications |
| CI/CD | All of the above | Source control, pipelines, container registry |

---

## Ecosystem Index

| Ecosystem | Document | Purpose |
|-----------|----------|---------|
| 1. Authentication &amp; Identity | [authentication-identity.md](./authentication-identity.md) | User authentication, service authorization, OIDC federation |
| 2. Networking &amp; Ingress | [networking-ingress.md](./networking-ingress.md) | Traffic routing, TLS termination, gateway policies |
| 3. PKI &amp; Certificates | [pki-certificates.md](./pki-certificates.md) | Certificate lifecycle, trust hierarchy, automated issuance |
| 4. CI/CD Pipeline | [cicd-pipeline.md](./cicd-pipeline.md) | Code commit to production, GitOps-driven deployment |
| 5. Observability &amp; Monitoring | [observability-monitoring.md](./observability-monitoring.md) | Metrics, logs, traces, alerts, and dashboards |
| 6. Data &amp; Storage | [data-storage.md](./data-storage.md) | Databases, caching, object storage, persistence |
| 7. Secrets &amp; Configuration | [secrets-configuration.md](./secrets-configuration.md) | Vault, credential management, external secret sync |

---

## Infrastructure Overview

### Cluster Layout

The Harvester RKE2 cluster spans 13 nodes optimized for different workload types:

- **3 Controlplane nodes** — Kubernetes API, etcd, scheduler (HA across failure domains)
- **4 Database nodes** — StatefulSet storage for PostgreSQL, Redis, Vault (labeled `workload-type: database`)
- **4 General nodes** — Stateless replicated services, HPA targets (labeled `workload-type: general`)
- **2 Compute nodes** — CI/CD job execution, batch workloads (labeled `workload-type: compute`)

### Node Selector Strategy

| Workload | Selector | Reason |
|----------|----------|--------|
| Vault, CNPG, Redis, MinIO | `workload-type: database` | Persistent storage, high I/O |
| Keycloak, Grafana, OAuth2-proxy, ArgoCD, Harbor | `workload-type: general` | Stateless with HPA |
| GitLab services, Prometheus | `workload-type: general` | Query aggregation, moderate state |
| GitLab Runners | `workload-type: compute` | CPU-intensive job execution |
| Monitoring agents (Alloy, Hubble) | DaemonSet on all nodes | Observability everywhere |

### Proactive Cluster Autoscaling

The platform uses **cluster-autoscaler overprovisioning** to ensure nodes are added before production workloads experience resource contention. Low-priority pause pods reserve capacity in each pool:

| Pool | Pause Pod Replicas | Reserved Capacity | Preemption |
|------|-------------------|-------------------|-----------|
| General | 2 | 4 CPU, 12 Gi memory | Production workloads trigger preemption → autoscaler adds nodes |
| Database | 2 | 4 CPU, 20 Gi memory | Storage-intensive services trigger preemption → autoscaler adds nodes |

When a real workload needs resources, pause pods are preempted and become Pending, immediately triggering cluster-autoscaler to provision a new node. This ensures production services never experience scheduling failures due to resource exhaustion.

### Domain and TLS

- **Primary domain**: `&lt;DOMAIN&gt;`
- **Service FQDNs**: `<service>.&lt;DOMAIN&gt;` (e.g., `harbor.&lt;DOMAIN&gt;`, `argocd.&lt;DOMAIN&gt;`)
- **TLS**: All external ingress encrypted with cert-manager-issued leaf certificates (3-year validity, auto-renewal at 30 days)
- **Root CA**: Offline, air-gapped; signs Vault intermediate; never touches cluster

---

## Service Catalog (28 Services across 65 Bundles)

| # | Service | Namespace | Ecosystem | HA Mode | Deployed |
|---|---------|-----------|-----------|---------|----------|
| 1 | Vault | `vault` | Secrets | 3-replica Raft | ✓ |
| 2 | cert-manager | `cert-manager` | PKI | 2-replica (controller, webhook, cainjector) + topology spread | ✓ |
| 3 | ESO Controller | `external-secrets` | Secrets | 2-replica (operator, webhook, cert-controller) + topology spread | ✓ |
| 4 | CNPG Operator | `cnpg-system` | Data | 2-replica leader/follower + topology spread | ✓ |
| 5 | Redis Operator | `redis-operator` | Data | 2-replica + topology spread | ✓ |
| 6 | Keycloak | `keycloak` | Identity | 3-replica + HPA | ✓ |
| 7 | CNPG (Keycloak DB) | `database` | Data | 3-replica PostgreSQL | ✓ |
| 8 | OAuth2-proxy | `keycloak` | Identity | 2-replica | ✓ |
| 9 | Prometheus | `monitoring` | Observability | 2-replica with `__replica__` external label for dedup + topology spread | ✓ |
| 10 | Grafana | `monitoring` | Observability | 2-replica + HPA | ✓ |
| 11 | Alertmanager | `monitoring` | Observability | 2-replica with mesh clustering + topology spread | ✓ |
| 12 | Loki | `monitoring` | Observability | 2-replica distributed (safe-to-evict=false for RWO PVC) | ✓ |
| 13 | Alloy | `monitoring` | Observability | DaemonSet (all nodes) | ✓ |
| 14 | Hubble | `cilium` | Observability | DaemonSet (all nodes) | ✓ |
| 15 | Harbor | `harbor` | CI/CD | 2-replica + HPA | ✓ |
| 16 | CNPG (Harbor DB) | `database` | Data | 3-replica PostgreSQL | ✓ |
| 17 | MinIO | `minio` | Data | Distributed object storage | ✓ |
| 18 | Valkey Cache | `harbor` | Data | 3-node Sentinel + replicas | ✓ |
| 19 | ArgoCD | `argocd` | CD | 3-replica + HPA | ✓ |
| 20 | Argo Rollouts Controller | `argo-rollouts` | CD | 2-replica | ✓ |
| 21 | Argo Workflows Controller | `argo-workflows` | CD | 2-replica | ✓ |
| 22 | GitLab EE | `gitlab` | CI/CD | 3-replica + HPA | ✓ |
| 23 | Praefect/Gitaly | `gitlab` | CI/CD | 3-replica Praefect + 3 Gitaly | ✓ |
| 24 | CNPG (GitLab DB) | `database` | Data | 3-replica PostgreSQL | ✓ |
| 25 | Redis Cache (GitLab) | `gitlab` | Data | 3-node Sentinel + replicas | ✓ |
| 26 | GitLab Runners | `gitlab-runners` | CI/CD | Horizontal pod autoscaling | ✓ |
| 27 | GitLab Credentials | (injected) | Secrets | PushSecret generators | ✓ |
| 28 | Backup MinIO | `backup` | Data | Single-instance S3-only (50Gi → 2Ti) | ✓ |

---

## Deployment Method

All platform services are deployed **via Fleet GitOps** as **65 HelmOp CRs** from a single unified script. Each HelmOp carries a `deploy-version` annotation that tracks the bundle version at deployment time, enabling quick verification of what version is running on any resource. The deployment workflow is:

```
./deploy.sh
├─ Phase 1: Push Helm charts to Harbor (upstream charts)
├─ Phase 2: Seed Root CA on downstream cluster
├─ Phase 3: Push OCI bundles to Harbor (raw manifests)
├─ Phase 4: Create 65 Fleet HelmOps on Rancher management cluster
├─ Phase 5: Sign Vault intermediate CSR with offline Root CA
└─ Phase 6: Seed manual secrets (GitLab license, watcher credentials, kubeconfigs)
```

Total deployment time: ~30-40 minutes (including 15-min wait for Vault initialization)

## Bundle Groups (65 Total across 9 Groups)

```mermaid
graph TD
    A["00-operators (8)"]
    B["05-pki-secrets (8)"]
    C["10-identity (4)"]
    D["11-infra-auth (3)"]
    J["15-dns (1)"]
    E["20-monitoring (7)"]
    K["35-backup (3)"]
    F["30-harbor (7)"]
    G["40-gitops (12)"]
    H["50-gitlab (10)"]
    I["60-cicd-onboard (3)"]

    A --> B
    B --> C
    C --> D
    D --> J
    D --> E
    D --> F
    D --> G
    F --> K
    F --> H
    E --> G
    H --> I
    F --> I

    style A fill:#198754,color:#fff
    style B fill:#dc3545,color:#fff
    style C fill:#6f42c1,color:#fff
    style D fill:#6f42c1,color:#fff
    style J fill:#6f42c1,color:#fff
    style E fill:#fd7e14,color:#fff
    style K fill:#20c997,color:#000
    style F fill:#0dcaf0,color:#000
    style G fill:#198754,color:#fff
    style H fill:#0d6efd,color:#fff
    style I fill:#ffc107,color:#000
```

**Key dependency insights:**
- 00-operators: Foundation operators (CNPG, Redis)
- 05-pki-secrets: PKI + Vault (foundation for all others)
- 10-identity: Keycloak OIDC + database + configuration
- 11-infra-auth: Auth gateways for infrastructure services
- 15-dns: External DNS secrets (depends on infra-auth)
- 20-monitoring: Observability stack (Prometheus, Grafana, Loki, Alloy)
- 30-harbor: Container registry (uses shared MinIO)
- 35-backup: Dedicated backup MinIO for cross-cluster backups (depends on Harbor for TLS)
- 40-gitops: ArgoCD + Rollouts + Workflows (12 bundles including analysis templates)
- 50-gitlab: Source control + CI/CD (10 bundles, includes shared + terraform runners)
- 60-cicd-onboard: App platform onboarding (shared RBAC + per-app Harbor/Keycloak provisioning)

---

## What's Next?

- **Full Landscape**: See [landscape.md](landscape.md) for a complete visual map of all 28 services and their interconnections
- **Getting Started**: Follow [../../getting-started.md](../../getting-started.md) for step-by-step deployment
- **Deep Dives**: Pick an ecosystem from the index above for technical architecture and configuration
- **Operations**: See [../operations/day2-operations.md](../operations/day2-operations.md) for runbooks and troubleshooting
