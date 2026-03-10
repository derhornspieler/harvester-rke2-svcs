# Platform Landscape

A visual tour of the complete Harvester RKE2 platform — 26 services across 13 nodes, explained one layer at a time.

---

## The Platform at 10,000 Feet

Six stacks build on each other. Security underpins everything, identity enables access control, and the remaining stacks layer on top. Read left-to-right: each stack depends on the ones before it.

```mermaid
graph LR
    subgraph S1["1. Security &amp; PKI"]
        direction TB
        Vault["Vault HA"]
        CM["cert-manager"]
        ESO["ESO"]
    end

    subgraph S2["2. Identity"]
        direction TB
        KC["Keycloak"]
        OAuth["OAuth2-proxy"]
    end

    subgraph S3["3. Observability"]
        direction TB
        Prom["Prometheus"]
        Grafana["Grafana"]
        Loki["Loki"]
    end

    subgraph S4["4. Registry"]
        direction TB
        Harbor["Harbor"]
    end

    subgraph S5["5. GitOps"]
        direction TB
        ArgoCD["ArgoCD"]
        Rollouts["Argo Rollouts"]
    end

    subgraph S6["6. CI/CD"]
        direction TB
        GitLab["GitLab EE"]
        Runners["Runners"]
    end

    S1 --> S2 --> S3 --> S4 --> S5 --> S6

    classDef pki fill:#dc3545,color:#fff,stroke:#a02030,stroke-width:2px
    classDef identity fill:#6f42c1,color:#fff,stroke:#4a2a7f,stroke-width:2px
    classDef obs fill:#fd7e14,color:#fff,stroke:#b15810,stroke-width:2px
    classDef data fill:#0dcaf0,color:#000,stroke:#0a9db5,stroke-width:2px
    classDef cicd fill:#198754,color:#fff,stroke:#0d5a32,stroke-width:2px
    classDef blue fill:#0d6efd,color:#fff,stroke:#0a58ca,stroke-width:2px

    class Vault,CM,ESO pki
    class KC,OAuth identity
    class Prom,Grafana,Loki obs
    class Harbor data
    class ArgoCD,Rollouts cicd
    class GitLab,Runners blue
```

The rest of this document zooms into each major interaction pattern, one at a time.

---

## How Certificates Flow

Every HTTPS endpoint on the platform gets its certificate through this chain. The Root CA is air-gapped and used exactly once — to sign Vault's intermediate. After that, cert-manager handles everything automatically.

```mermaid
graph TD
    RootCA["Offline Root CA<br/>Air-gapped, RSA 4096, 30yr"]
    VaultPKI["Vault PKI Engine<br/>Intermediate CA, online"]
    CertMgr["cert-manager<br/>ClusterIssuer: vault-issuer"]

    RootCA -- "signs once, then goes offline" --> VaultPKI
    VaultPKI -- "issues on demand" --> CertMgr

    CertMgr --> KC_cert["Keycloak TLS"]
    CertMgr --> Graf_cert["Grafana TLS"]
    CertMgr --> Harbor_cert["Harbor TLS"]
    CertMgr --> Argo_cert["ArgoCD TLS"]
    CertMgr --> GL_cert["GitLab TLS"]
    CertMgr --> Traefik_cert["Traefik Gateway TLS"]

    classDef offline fill:#6c757d,color:#fff,stroke:#495057,stroke-width:3px
    classDef pki fill:#dc3545,color:#fff,stroke:#a02030,stroke-width:2px
    classDef leaf fill:#f8d7da,color:#721c24,stroke:#f5c6cb,stroke-width:1px

    class RootCA offline
    class VaultPKI,CertMgr pki
    class KC_cert,Graf_cert,Harbor_cert,Argo_cert,GL_cert,Traefik_cert leaf
```

---

## How Secrets Get to Services

No service reads secrets directly. Vault stores everything, and ESO syncs credentials into Kubernetes Secrets per namespace. Each namespace has its own SecretStore with a scoped Vault role — no service can read another's secrets.

```mermaid
graph LR
    Vault["Vault<br/>KV v2 engine"]
    ESO["External Secrets<br/>Operator"]

    Vault -- "AppRole auth<br/>per namespace" --> ESO

    ESO -- "keycloak ns" --> KC_sec["Keycloak<br/>DB password, OIDC secret"]
    ESO -- "harbor ns" --> HB_sec["Harbor<br/>DB, MinIO, admin creds"]
    ESO -- "argocd ns" --> Argo_sec["ArgoCD<br/>OIDC client, repo creds"]
    ESO -- "gitlab ns" --> GL_sec["GitLab<br/>DB, Redis, SMTP, OIDC"]

    classDef vault fill:#dc3545,color:#fff,stroke:#a02030,stroke-width:2px
    classDef eso fill:#d63384,color:#fff,stroke:#a02060,stroke-width:2px
    classDef secret fill:#ffe0ec,color:#6b1d3a,stroke:#d63384,stroke-width:1px

    class Vault vault
    class ESO eso
    class KC_sec,HB_sec,Argo_sec,GL_sec secret
```

---

## Who Logs In Where

Keycloak is the single identity provider. Some services integrate directly via OIDC; others sit behind OAuth2-proxy, which handles authentication at the gateway level so the service itself doesn't need to.

```mermaid
graph TD
    User(["User"])
    KC["Keycloak<br/>OIDC Provider"]

    User -- "authenticate" --> KC

    subgraph direct["Direct OIDC Integration"]
        direction LR
        Grafana["Grafana"]
        ArgoCD["ArgoCD"]
        GitLab["GitLab"]
        Harbor["Harbor"]
    end

    subgraph proxy["Protected by OAuth2-proxy"]
        direction LR
        OAuth["OAuth2-proxy<br/>S256 PKCE"]
        Prom["Prometheus"]
        Alert["Alertmanager"]
        HubbleUI["Hubble UI"]
    end

    KC -- "OIDC token" --> direct
    KC -- "OIDC + PKCE" --> OAuth
    OAuth -- "authenticated" --> Prom
    OAuth -- "authenticated" --> Alert
    OAuth -- "authenticated" --> HubbleUI

    classDef user fill:#fff,color:#333,stroke:#333,stroke-width:2px
    classDef identity fill:#6f42c1,color:#fff,stroke:#4a2a7f,stroke-width:2px
    classDef app fill:#e8dff5,color:#4a2a7f,stroke:#6f42c1,stroke-width:1px
    classDef protected fill:#fff3cd,color:#664d03,stroke:#ffc107,stroke-width:1px

    class User user
    class KC,OAuth identity
    class Grafana,ArgoCD,GitLab,Harbor app
    class Prom,Alert,HubbleUI protected
```

---

## The CI/CD Pipeline

Code flows from left to right: a developer pushes to GitLab, Runners build and test, images land in Harbor, and ArgoCD deploys to the cluster. Argo Rollouts handles progressive delivery (canary or blue-green) for production workloads.

```mermaid
graph LR
    Dev(["Developer"])
    GL["GitLab EE<br/>Source + Pipelines"]
    Run["GitLab Runners<br/>Build + Test"]
    Harb["Harbor<br/>Container Registry"]
    Argo["ArgoCD<br/>GitOps Sync"]
    Roll["Argo Rollouts<br/>Canary / Blue-Green"]
    Cluster(["Production<br/>Workloads"])

    Dev -- "git push" --> GL
    GL -- "trigger pipeline" --> Run
    Run -- "push image" --> Harb
    Harb -- "image available" --> Argo
    Argo -- "sync manifests" --> Roll
    Roll -- "progressive rollout" --> Cluster

    classDef user fill:#fff,color:#333,stroke:#333,stroke-width:2px
    classDef cicd fill:#198754,color:#fff,stroke:#0d5a32,stroke-width:2px
    classDef registry fill:#0dcaf0,color:#000,stroke:#0a9db5,stroke-width:2px

    class Dev,Cluster user
    class GL,Run,Argo,Roll cicd
    class Harb registry
```

---

## What Watches Everything

Observability runs on every node and scrapes every service. Logs and metrics flow into separate stores but converge in Grafana for a unified view. Alertmanager routes notifications when thresholds are breached.

```mermaid
graph TD
    subgraph collectors["Collectors -- every node"]
        direction LR
        Alloy["Alloy<br/>Log Collector<br/>DaemonSet"]
        Hubble["Hubble<br/>Network Flows<br/>DaemonSet"]
    end

    subgraph targets["Scrape Targets"]
        direction LR
        T1["Keycloak"]
        T2["Harbor"]
        T3["GitLab"]
        T4["ArgoCD"]
        T5["Vault"]
        T6["CNPG x3"]
    end

    Prom["Prometheus<br/>2-replica"]
    Loki["Loki<br/>2-replica"]
    AM["Alertmanager<br/>2-replica mesh"]
    Grafana["Grafana<br/>Dashboards"]

    targets -- "metrics" --> Prom
    Alloy -- "logs" --> Loki
    Hubble -- "network flows" --> Loki
    Prom -- "fire alerts" --> AM
    Prom -- "PromQL" --> Grafana
    Loki -- "LogQL" --> Grafana

    classDef obs fill:#fd7e14,color:#fff,stroke:#b15810,stroke-width:2px
    classDef target fill:#fff5e6,color:#7a4100,stroke:#fd7e14,stroke-width:1px
    classDef collector fill:#ffe8cc,color:#7a4100,stroke:#fd7e14,stroke-width:1px

    class Prom,Loki,AM,Grafana obs
    class T1,T2,T3,T4,T5,T6 target
    class Alloy,Hubble collector
```

---

## Where Data Lives

Three services need relational databases (PostgreSQL via CNPG), two need caches (Redis/Valkey), and two need object storage (MinIO). Each database cluster runs 3 replicas with automatic failover. MinIO is shared but with isolated access keys per consumer.

```mermaid
graph TD
    subgraph postgres["PostgreSQL HA -- CNPG Operator"]
        direction LR
        pg_pad[ ]:::hidden
        PG_KC["Keycloak DB<br/>3-replica"]
        PG_HB["Harbor DB<br/>3-replica"]
        PG_GL["GitLab DB<br/>3-replica"]
    end

    subgraph cache["Cache -- Redis/Valkey Sentinel"]
        direction LR
        ca_pad[ ]:::hidden
        Redis_GL["Redis<br/>GitLab<br/>3-node"]
        Valkey_HB["Valkey<br/>Harbor<br/>3-node"]
    end

    subgraph object["Object Storage -- MinIO"]
        ob_pad[ ]:::hidden
        MinIO["MinIO<br/>Shared Instance"]
    end

    PG_KC --> KC["Keycloak"]
    PG_HB --> HB["Harbor"]
    PG_GL --> GL["GitLab"]
    Redis_GL --> GL
    Valkey_HB --> HB
    MinIO -- "artifacts, backups" --> GL
    MinIO -- "blob storage" --> HB

    classDef data fill:#0dcaf0,color:#000,stroke:#0a9db5,stroke-width:2px
    classDef app fill:#e0f7fa,color:#004d57,stroke:#0dcaf0,stroke-width:1px

    class PG_KC,PG_HB,PG_GL,Redis_GL,Valkey_HB,MinIO data
    class KC,HB,GL app
    classDef hidden display:none
```

---

## Node Placement

The cluster has 4 node types. Stateful workloads land on database nodes (fast disks), stateless services on general nodes (HPA scales them), CI jobs on dedicated compute nodes, and DaemonSets run everywhere.

```mermaid
graph TB
    subgraph cp["Controlplane -- 3 nodes"]
        direction LR
        cp1["etcd + API server + scheduler"]
    end

    subgraph db["Database Nodes -- 4 nodes, workload-type: database"]
        direction LR
        db1["Vault HA"]
        db2["CNPG x3 clusters"]
        db3["Redis + Valkey"]
        db4["MinIO"]
    end

    subgraph gen["General Nodes -- 4 nodes, workload-type: general"]
        direction LR
        gen1["Keycloak, OAuth2-proxy"]
        gen2["Grafana, Prometheus, Alertmanager, Loki"]
        gen3["Harbor, ArgoCD, Argo Rollouts, Argo Workflows"]
        gen4["GitLab EE, Praefect + Gitaly"]
    end

    subgraph comp["Compute Nodes -- 2 nodes, workload-type: compute"]
        direction LR
        comp1["GitLab Runners"]
    end

    subgraph daemon["DaemonSet -- all 13 nodes"]
        direction LR
        d1["Alloy"]
        d2["Hubble"]
        d3["Traefik"]
    end

    classDef cpn fill:#495057,color:#fff,stroke:#343a40,stroke-width:2px
    classDef dbn fill:#0dcaf0,color:#000,stroke:#0a9db5,stroke-width:2px
    classDef genn fill:#198754,color:#fff,stroke:#0d5a32,stroke-width:2px
    classDef compn fill:#0d6efd,color:#fff,stroke:#0a58ca,stroke-width:2px
    classDef dmn fill:#fd7e14,color:#fff,stroke:#b15810,stroke-width:2px

    class cp1 cpn
    class db1,db2,db3,db4 dbn
    class gen1,gen2,gen3,gen4 genn
    class comp1 compn
    class d1,d2,d3 dmn
```

---

## Deployment Bundle Sequence

Each bundle is deployed in order via Fleet GitOps. A bundle cannot deploy until its dependencies are running. The entire platform stands up in about 50 minutes.

```mermaid
graph TB
    subgraph B1["Bundle 1 -- PKI &amp; Secrets"]
        direction LR
        b1_vault["Vault HA"]
        b1_cm["cert-manager"]
        b1_eso["ESO"]
        b1_cnpg_op["CNPG Operator"]
        b1_redis_op["Redis Operator"]
    end

    subgraph B2["Bundle 2 -- Identity"]
        direction LR
        b2_kc["Keycloak"]
        b2_oauth["OAuth2-proxy"]
        b2_cnpg["CNPG Keycloak"]
    end

    subgraph B3["Bundle 3 -- Monitoring"]
        direction LR
        b3_prom["Prometheus"]
        b3_graf["Grafana"]
        b3_loki["Loki"]
        b3_alloy["Alloy"]
        b3_hub["Hubble"]
        b3_am["Alertmanager"]
    end

    subgraph B4["Bundle 4 -- Harbor"]
        direction LR
        b4_harbor["Harbor"]
        b4_cnpg["CNPG Harbor"]
        b4_minio["MinIO"]
        b4_valkey["Valkey"]
    end

    subgraph B5["Bundle 5 -- GitOps"]
        direction LR
        b5_argo["ArgoCD"]
        b5_ro["Argo Rollouts"]
        b5_wf["Argo Workflows"]
    end

    subgraph B6["Bundle 6 -- Git &amp; CI"]
        direction LR
        b6_gl["GitLab EE"]
        b6_run["Runners"]
        b6_prae["Praefect + Gitaly"]
        b6_cnpg["CNPG GitLab"]
        b6_redis["Redis Sentinel"]
    end

    B1 -- "TLS + secrets ready" --> B2
    B2 -- "OIDC available" --> B3
    B3 -- "monitoring online" --> B4
    B4 -- "registry available" --> B5
    B5 -- "GitOps engine ready" --> B6

    classDef pki fill:#dc3545,color:#fff,stroke:#a02030,stroke-width:2px
    classDef identity fill:#6f42c1,color:#fff,stroke:#4a2a7f,stroke-width:2px
    classDef obs fill:#fd7e14,color:#fff,stroke:#b15810,stroke-width:2px
    classDef data fill:#0dcaf0,color:#000,stroke:#0a9db5,stroke-width:2px
    classDef cicd fill:#198754,color:#fff,stroke:#0d5a32,stroke-width:2px
    classDef blue fill:#0d6efd,color:#fff,stroke:#0a58ca,stroke-width:2px

    class b1_vault,b1_cm,b1_eso,b1_cnpg_op,b1_redis_op pki
    class b2_kc,b2_oauth,b2_cnpg identity
    class b3_prom,b3_graf,b3_loki,b3_alloy,b3_hub,b3_am obs
    class b4_harbor,b4_cnpg,b4_minio,b4_valkey data
    class b5_argo,b5_ro,b5_wf cicd
    class b6_gl,b6_run,b6_prae,b6_cnpg,b6_redis blue
```

---

## Namespace Map

Every service lives in a dedicated namespace. Services that work together (like Keycloak and its database) share a namespace. This table maps where everything runs.

| Namespace | Services | Ecosystem |
|-----------|----------|-----------|
| `vault` | Vault HA (3-replica Raft) | Security |
| `cert-manager` | cert-manager (controller, webhook, cainjector) | Security |
| `external-secrets` | ESO (operator, webhook, cert-controller) | Security |
| `cnpg-system` | CNPG Operator | Operators |
| `redis-operator` | Redis Operator | Operators |
| `keycloak` | Keycloak (3-replica), OAuth2-proxy (2-replica), CNPG PostgreSQL (3-replica) | Identity |
| `monitoring` | Prometheus (2-replica), Grafana (2-replica), Alertmanager (2-replica), Loki (2-replica), Alloy (DaemonSet) | Observability |
| `cilium` | Hubble (DaemonSet + Relay) | Observability |
| `harbor` | Harbor (2-replica), CNPG PostgreSQL (3-replica), Valkey Sentinel (3-node) | Registry |
| `minio` | MinIO (shared instance) | Storage |
| `argocd` | ArgoCD (3-replica) | GitOps |
| `argo-rollouts` | Argo Rollouts (2-replica) | GitOps |
| `argo-workflows` | Argo Workflows (2-replica) | GitOps |
| `gitlab` | GitLab EE (3-replica), Praefect (3) + Gitaly (3), CNPG PostgreSQL (3-replica), Redis Sentinel (3-node) | CI/CD |
| `gitlab-runners` | GitLab Runners (HPA autoscaled) | CI/CD |

---

## Related Documentation

- [Platform Overview](overview.md) -- Executive summary and service catalog
- [Diagram Reference](DIAGRAM_REFERENCE.md) -- Color scheme and naming conventions
- [Authentication &amp; Identity](authentication-identity.md) -- OIDC flows and access control
- [PKI &amp; Certificates](pki-certificates.md) -- Certificate lifecycle and trust chain
- [CI/CD Pipeline](cicd-pipeline.md) -- Code to production workflow
- [Observability &amp; Monitoring](observability-monitoring.md) -- Metrics, logs, and alerts
- [Data &amp; Storage](data-storage.md) -- Database and object storage architecture
- [Secrets &amp; Configuration](secrets-configuration.md) -- Vault and ESO integration
- [Networking &amp; Ingress](networking-ingress.md) -- Traffic routing and TLS termination
