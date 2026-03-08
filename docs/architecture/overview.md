# Platform Overview

## Executive Summary

This platform delivers a production-grade GitOps foundation on a 13-node Harvester RKE2 cluster, providing secure, observable, self-healing infrastructure for containerized workloads. It combines identity management (Keycloak + OAuth2-proxy), container registry (Harbor), policy-driven deployments (ArgoCD), and Git-native CI/CD (GitLab + Runners), all protected by zero-trust PKI and automated secrets management. Leadership gains visibility through integrated monitoring (Prometheus, Grafana, Loki) and audit trails across all ecosystems.

---

## Platform at a Glance

The platform is organized into six stacks. Each stack is self-contained and deployed as a bundle.

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
| Identity &amp; Access | Security (certs, secrets) | Single sign-on to Platform, CI/CD, Observability |
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

### Domain and TLS

- **Primary domain**: `&lt;DOMAIN&gt;`
- **Service FQDNs**: `<service>.&lt;DOMAIN&gt;` (e.g., `harbor.&lt;DOMAIN&gt;`, `argocd.&lt;DOMAIN&gt;`)
- **TLS**: All external ingress encrypted with cert-manager-issued leaf certificates (3-year validity, auto-renewal at 30 days)
- **Root CA**: Offline, air-gapped; signs Vault intermediate; never touches cluster

---

## Service Catalog

| # | Service | Namespace | Ecosystem | HA Mode | Bundle | Deployed |
|---|---------|-----------|-----------|---------|--------|----------|
| 1 | Vault | `vault` | Secrets | 3-replica Raft | 1 | ✓ |
| 2 | cert-manager | `cert-manager` | PKI | 3-replica leader/follower | 1 | ✓ |
| 3 | ESO Controller | `external-secrets` | Secrets | 2-replica | 1 | ✓ |
| 4 | Keycloak | `keycloak` | Identity | 3-replica + HPA | 2 | ✓ |
| 5 | CNPG (Keycloak DB) | `keycloak` | Data | 3-replica PostgreSQL | 2 | ✓ |
| 6 | OAuth2-proxy | `keycloak` | Identity | 2-replica | 2 | ✓ |
| 7 | Prometheus | `monitoring` | Observability | 2-replica federated | 3 | ✓ |
| 8 | Grafana | `monitoring` | Observability | 2-replica + HPA | 3 | ✓ |
| 9 | Alertmanager | `monitoring` | Observability | 3-replica | 3 | ✓ |
| 10 | Loki | `monitoring` | Observability | 2-replica distributed | 3 | ✓ |
| 11 | Alloy | `monitoring` | Observability | DaemonSet (all nodes) | 3 | ✓ |
| 12 | Harbor | `harbor` | CI/CD | 2-replica + HPA | 4 | ✓ |
| 13 | CNPG (Harbor DB) | `harbor` | Data | 3-replica PostgreSQL | 4 | ✓ |
| 14 | MinIO | `harbor` | Data | 4-node distributed | 4 | ✓ |
| 15 | Valkey Sentinel | `harbor` | Data | 3-node Sentinel + replicas | 4 | ✓ |
| 16 | ArgoCD | `argocd` | CI/CD | 3-replica + HPA | 5 | ✓ |
| 17 | Argo Rollouts | `argo-rollouts` | CI/CD | 2-replica | 5 | ✓ |
| 18 | Argo Workflows | `argo-workflows` | CI/CD | 2-replica | 5 | ✓ |
| 19 | GitLab EE | `gitlab` | CI/CD | 3-replica + HPA | 6 | ✓ |
| 20 | Praefect/Gitaly | `gitlab` | CI/CD | 3-replica Praefect + 3 Gitaly | 6 | ✓ |
| 21 | CNPG (GitLab DB) | `gitlab` | Data | 3-replica PostgreSQL | 6 | ✓ |
| 22 | Redis Sentinel | `gitlab` | Data | 3-node Sentinel + replicas | 6 | ✓ |
| 23 | GitLab Runners | `gitlab-runners` | CI/CD | Horizontal pod autoscaling | 6 | ✓ |

---

## Deployment Order

```mermaid
graph LR
    S1["PKI &amp; Secrets"]
    S2["Identity"]
    S3["Monitoring"]
    S4["Harbor"]
    S5["GitOps"]
    S6["Git &amp; CI"]

    S1 --> S2 --> S3 --> S4 --> S5 --> S6

    style S1 fill:#dc3545,color:#fff,stroke:#a02030,stroke-width:3px
    style S2 fill:#6f42c1,color:#fff,stroke:#4a2a7f,stroke-width:3px
    style S3 fill:#fd7e14,color:#fff,stroke:#b15810,stroke-width:3px
    style S4 fill:#0dcaf0,color:#000,stroke:#0a9db5,stroke-width:3px
    style S5 fill:#198754,color:#fff,stroke:#0d5a32,stroke-width:3px
    style S6 fill:#0d6efd,color:#fff,stroke:#0a58ca,stroke-width:3px
```

Stacks deploy in sequence because each depends on earlier stacks for TLS, secrets, or OIDC:

1. **PKI &amp; Secrets** — foundation; everything depends on this
2. **Identity** — enables OIDC for downstream services
3. **Monitoring** — recommended before application stacks
4. **Harbor** — container registry; required before CI/CD
5. **GitOps** — ArgoCD + Rollouts; requires Git source from step 6
6. **Git &amp; CI** — GitLab + Runners complete the loop

---

## What's Next?

- **Getting Started**: Follow [../../getting-started.md](../../getting-started.md) for step-by-step deployment
- **Deep Dives**: Pick an ecosystem from the index above for technical architecture and configuration
- **Operations**: See [../operations/day2-operations.md](../operations/day2-operations.md) for runbooks and troubleshooting
