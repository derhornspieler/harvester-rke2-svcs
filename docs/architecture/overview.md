# Platform Overview

## Executive Summary

This platform delivers a production-grade GitOps foundation on a 13-node Harvester RKE2 cluster, providing secure, observable, self-healing infrastructure for containerized workloads. It combines identity management (Keycloak + OAuth2-proxy), container registry (Harbor), policy-driven deployments (ArgoCD), and Git-native CI/CD (GitLab + Runners), all protected by zero-trust PKI and automated secrets management. Leadership gains visibility through integrated monitoring (Prometheus, Grafana, Loki) and audit trails across all ecosystems.

---

## Master Platform Diagram

```mermaid
graph TD
    subgraph AuthId["🔐 Authentication &amp; Identity"]
        KC["Keycloak<br/>OIDC Provider"]
        OAuth["OAuth2-proxy<br/>Service Protector"]
    end

    subgraph Net["🌐 Networking &amp; Ingress"]
        Traefik["Traefik<br/>API Gateway"]
        GW["Gateway API<br/>HTTPRoutes &amp; Middleware"]
    end

    subgraph PKI["🔑 PKI &amp; Certificates"]
        RootCA["Offline Root CA<br/>(Air-gapped)"]
        Vault["Vault<br/>Intermediate CA + KV Secrets"]
        CM["cert-manager<br/>Leaf Certificate Issuer"]
    end

    subgraph CICD["🚀 CI/CD Pipeline"]
        GL["GitLab<br/>Repository + CI/CD"]
        Runners["GitLab Runners<br/>Job Execution"]
        Harbor["Harbor<br/>Container Registry"]
        ArgoCD["ArgoCD<br/>Policy-Driven Deployment"]
        Rollouts["Argo Rollouts<br/>Progressive Delivery"]
    end

    subgraph Obs["📊 Observability &amp; Monitoring"]
        Prom["Prometheus<br/>Metrics Collection"]
        Graf["Grafana<br/>Visualization &amp; Dashboards"]
        Loki["Loki<br/>Log Aggregation"]
        Alloy["Alloy<br/>Log Collector"]
        Hubble["Hubble<br/>Network Observability"]
        AM["Alertmanager<br/>Alert Routing"]
    end

    subgraph Data["💾 Data &amp; Storage"]
        CNPG["CloudNativePG<br/>(3x PostgreSQL HA)"]
        Redis["Redis/Valkey Sentinel<br/>(Cache + Session)"]
        MinIO["MinIO<br/>(S3-compatible Storage)"]
    end

    subgraph Secrets["🔓 Secrets &amp; Configuration"]
        ESO["External Secrets Operator<br/>Sync to Vault"]
        SecretStore["SecretStores<br/>(Vault Integration)"]
    end

    RootCA -->|signs| Vault
    Vault -->|pki_int/sign| CM
    Vault -->|kv/data| ESO

    ESO -->|sync| SecretStore
    SecretStore -->|inject| GL
    SecretStore -->|inject| KC
    SecretStore -->|inject| ArgoCD
    SecretStore -->|inject| Harbor

    CM -->|leaf certs| Traefik
    CM -->|leaf certs| Graf
    CM -->|leaf certs| KC
    CM -->|leaf certs| Harbor
    CM -->|leaf certs| GL
    CM -->|leaf certs| ArgoCD

    KC -->|OIDC| OAuth
    KC -->|OIDC| ArgoCD
    KC -->|OIDC| Graf
    KC -->|OIDC| GL

    OAuth -->|protects| Prom
    OAuth -->|protects| Graf
    OAuth -->|protects| ArgoCD

    Traefik -->|routes| KC
    Traefik -->|routes| Graf
    Traefik -->|routes| Prom
    Traefik -->|routes| Harbor
    Traefik -->|routes| GL
    Traefik -->|routes| ArgoCD

    GW -->|TLS + auth| Traefik

    GL -->|triggers| Runners
    Runners -->|push images| Harbor
    Runners -->|commit triggers| ArgoCD

    ArgoCD -->|deploy| CICD
    ArgoCD -->|deploy| Obs
    ArgoCD -->|deploy| Data

    Rollouts -->|canary/blue-green| GL

    CNPG -->|stores| GL
    CNPG -->|stores| KC
    CNPG -->|stores| Harbor
    CNPG -->|stores| ArgoCD

    Redis -->|caches| GL
    Redis -->|caches| KC
    Redis -->|caches| Harbor

    MinIO -->|backend| Harbor
    MinIO -->|backup| GL

    Alloy -->|logs| Loki
    Hubble -->|network flow| Loki

    Prom -->|scrapes all| KC
    Prom -->|scrapes all| Harbor
    Prom -->|scrapes all| GL
    Prom -->|scrapes all| ArgoCD
    Prom -->|scrapes all| CNPG
    Prom -->|scrapes all| Redis

    Prom -->|alerts| AM
    AM -->|notifies| Traefik

    Graf -->|visualizes| Prom
    Graf -->|visualizes| Loki
    Loki -->|indexed by| Hubble

    classDef secStyle fill:#dc3545,color:#fff,stroke:#a02030,stroke-width:3px
    classDef idStyle fill:#6f42c1,color:#fff,stroke:#4a2a7f,stroke-width:3px
    classDef netStyle fill:#0d6efd,color:#fff,stroke:#0a4fa3,stroke-width:3px
    classDef cicdStyle fill:#198754,color:#fff,stroke:#0d5a32,stroke-width:3px
    classDef obsStyle fill:#fd7e14,color:#fff,stroke:#b15810,stroke-width:3px
    classDef dataStyle fill:#0dcaf0,color:#000,stroke:#0a9db5,stroke-width:3px
    classDef secretStyle fill:#d63384,color:#fff,stroke:#9e2460,stroke-width:3px

    class RootCA,Vault,CM secStyle
    class KC,OAuth idStyle
    class Traefik,GW netStyle
    class GL,Runners,Harbor,ArgoCD,Rollouts cicdStyle
    class Prom,Graf,Loki,Alloy,Hubble,AM obsStyle
    class CNPG,Redis,MinIO dataStyle
    class ESO,SecretStore secretStyle
```

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

## Bundle Dependency Graph

```mermaid
graph LR
    B1["<b>Bundle 1</b><br/>PKI &amp; Secrets<br/>(Vault, cert-manager, ESO)"]
    B2["<b>Bundle 2</b><br/>Identity<br/>(Keycloak, OAuth2-proxy)"]
    B3["<b>Bundle 3</b><br/>Monitoring<br/>(Prometheus, Grafana, Loki)"]
    B4["<b>Bundle 4</b><br/>Harbor<br/>(Registry, MinIO)"]
    B5["<b>Bundle 5</b><br/>GitOps<br/>(ArgoCD, Rollouts)"]
    B6["<b>Bundle 6</b><br/>Git &amp; CI<br/>(GitLab, Runners)"]

    B1 -->|TLS certs| B2
    B1 -->|secrets| B2

    B1 -->|TLS certs| B3
    B1 -->|secrets| B3

    B1 -->|TLS certs| B4
    B1 -->|secrets| B4
    B1 -->|CNPG operator| B4

    B2 -->|OIDC| B3
    B3 -->|dashboards| B4

    B1 -->|TLS certs| B5
    B1 -->|secrets| B5
    B2 -->|OIDC| B5

    B1 -->|TLS certs| B6
    B1 -->|secrets| B6
    B2 -->|OIDC| B6
    B4 -->|image registry| B6

    B6 -->|Git + OIDC| B5

    style B1 fill:#dc3545,color:#fff,stroke:#a02030,stroke-width:3px
    style B2 fill:#6f42c1,color:#fff,stroke:#4a2a7f,stroke-width:3px
    style B3 fill:#fd7e14,color:#fff,stroke:#b15810,stroke-width:3px
    style B4 fill:#0dcaf0,color:#000,stroke:#0a9db5,stroke-width:3px
    style B5 fill:#198754,color:#fff,stroke:#0d5a32,stroke-width:3px
    style B6 fill:#ef6c00,color:#fff,stroke:#b85a00,stroke-width:3px
```

### Deployment Order

Bundles must deploy in sequence (1 → 6) because each depends on earlier bundles for TLS, secrets, or OIDC:

1. **Bundle 1** (PKI &amp; Secrets) — foundation; everything depends on this
2. **Bundle 2** (Identity) — enables OIDC for downstream services
3. **Bundle 3** (Monitoring) — optional but recommended before moving to data services
4. **Bundle 4** (Harbor) — container registry; required before CI/CD
5. **Bundle 5** (GitOps) — GitOps platform; requires Bundle 6 Git source
6. **Bundle 6** (Git &amp; CI) — final bundle; GitLab + Runners complete the loop

---

## What's Next?

- **Getting Started**: Follow [../../getting-started.md](../../getting-started.md) for step-by-step deployment
- **Deep Dives**: Pick an ecosystem from the index above for technical architecture and configuration
- **Operations**: See [../operations/day2-operations.md](../operations/day2-operations.md) for runbooks and troubleshooting
