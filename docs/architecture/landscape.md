# Platform Landscape

Full visualization of the deployed Harvester RKE2 platform — all 26 services, their interconnections, and data flows across 13 nodes.

---

## Complete Platform Topology

This diagram shows every service, how they connect, and which infrastructure layer they depend on.

```mermaid
graph LR
    subgraph NODES["13-Node Harvester RKE2 Cluster"]
        direction TB

        subgraph CP["Controlplane Nodes 3"]
            direction LR
            etcd["etcd"]
            api["kube-apiserver"]
            sched["scheduler"]
        end

        subgraph DB["Database Nodes 4 -- workload-type: database"]
            direction TB
            VaultHA["Vault HA<br/>3-replica Raft"]
            CNPG_KC["CNPG<br/>Keycloak DB<br/>3-replica"]
            CNPG_HB["CNPG<br/>Harbor DB<br/>3-replica"]
            CNPG_GL["CNPG<br/>GitLab DB<br/>3-replica"]
            RedisGL["Redis Sentinel<br/>GitLab<br/>3-node"]
            ValkeyHB["Valkey Sentinel<br/>Harbor<br/>3-node"]
            MinIOShared["MinIO<br/>Shared Object Store"]
        end

        subgraph GEN["General Nodes 4 -- workload-type: general"]
            direction TB
            KC["Keycloak<br/>3-replica + HPA"]
            OAuth["OAuth2-proxy<br/>2-replica"]
            Grafana["Grafana<br/>2-replica + HPA"]
            Prom["Prometheus<br/>2-replica"]
            AM["Alertmanager<br/>2-replica mesh"]
            Loki["Loki<br/>2-replica distributed"]
            HarborCore["Harbor<br/>2-replica + HPA"]
            ArgoCD["ArgoCD<br/>3-replica + HPA"]
            ArgoRO["Argo Rollouts<br/>2-replica"]
            ArgoWF["Argo Workflows<br/>2-replica"]
            GitLabEE["GitLab EE<br/>3-replica + HPA"]
            Praefect["Praefect + Gitaly<br/>3+3 replica"]
        end

        subgraph COMP["Compute Nodes 2 -- workload-type: compute"]
            direction TB
            Runners["GitLab Runners<br/>HPA autoscaled"]
        end

        subgraph DAEMON["DaemonSet -- All Nodes"]
            direction LR
            Alloy["Alloy<br/>Log Collector"]
            Hubble["Hubble<br/>Network Flows"]
            Traefik["Traefik<br/>Ingress Gateway"]
        end

        subgraph GLOBAL["Cluster-wide Services"]
            direction LR
            CertMgr["cert-manager<br/>2-replica"]
            ESO["ESO Controller<br/>2-replica"]
            CNPGOp["CNPG Operator<br/>2-replica"]
            RedisOp["Redis Operator<br/>2-replica"]
        end
    end

    subgraph OFFLINE["Air-gapped / Offline"]
        RootCA["Offline Root CA<br/>RSA 4096, 30yr"]
    end

    %% --- PKI Chain ---
    RootCA -. "signs (once)" .-> VaultHA
    VaultHA -- "issues intermediate" --> CertMgr
    CertMgr -- "leaf certs" --> Traefik
    CertMgr -- "leaf certs" --> KC
    CertMgr -- "leaf certs" --> Grafana
    CertMgr -- "leaf certs" --> HarborCore
    CertMgr -- "leaf certs" --> ArgoCD
    CertMgr -- "leaf certs" --> GitLabEE

    %% --- Secrets Injection ---
    VaultHA -- "KV v2" --> ESO
    ESO -- "ExternalSecret" --> KC
    ESO -- "ExternalSecret" --> HarborCore
    ESO -- "ExternalSecret" --> ArgoCD
    ESO -- "ExternalSecret" --> GitLabEE

    %% --- OIDC Identity ---
    KC -- "OIDC" --> Grafana
    KC -- "OIDC" --> ArgoCD
    KC -- "OIDC" --> GitLabEE
    KC -- "OIDC + PKCE" --> OAuth
    OAuth -- "protects" --> Prom
    OAuth -- "protects" --> AM

    %% --- Data Persistence ---
    CNPG_KC -- "PostgreSQL" --> KC
    CNPG_HB -- "PostgreSQL" --> HarborCore
    CNPG_GL -- "PostgreSQL" --> GitLabEE
    RedisGL -- "cache/session" --> GitLabEE
    ValkeyHB -- "cache" --> HarborCore
    MinIOShared -- "S3 objects" --> HarborCore
    MinIOShared -- "S3 backups" --> GitLabEE

    %% --- CI/CD Pipeline ---
    GitLabEE -- "trigger jobs" --> Runners
    Runners -- "push images" --> HarborCore
    HarborCore -- "pull images" --> ArgoCD
    ArgoCD -- "deploy" --> ArgoRO
    ArgoRO -- "canary/blue-green" --> ArgoWF

    %% --- Observability ---
    Prom -- "scrapes" --> KC
    Prom -- "scrapes" --> HarborCore
    Prom -- "scrapes" --> GitLabEE
    Prom -- "scrapes" --> ArgoCD
    Prom -- "scrapes" --> VaultHA
    Prom -- "scrapes" --> CNPG_KC
    Prom -- "scrapes" --> CNPG_HB
    Prom -- "scrapes" --> CNPG_GL
    Prom -- "alerts" --> AM
    Alloy -- "logs" --> Loki
    Hubble -- "network flows" --> Loki
    Loki -- "query" --> Grafana
    Prom -- "query" --> Grafana

    %% --- Operators ---
    CNPGOp -. "manages" .-> CNPG_KC
    CNPGOp -. "manages" .-> CNPG_HB
    CNPGOp -. "manages" .-> CNPG_GL
    RedisOp -. "manages" .-> RedisGL
    RedisOp -. "manages" .-> ValkeyHB

    %% --- Styles ---
    classDef pki fill:#dc3545,color:#fff,stroke:#a02030,stroke-width:2px
    classDef identity fill:#6f42c1,color:#fff,stroke:#4a2a7f,stroke-width:2px
    classDef obs fill:#fd7e14,color:#fff,stroke:#b15810,stroke-width:2px
    classDef cicd fill:#198754,color:#fff,stroke:#0d5a32,stroke-width:2px
    classDef data fill:#0dcaf0,color:#000,stroke:#0a9db5,stroke-width:2px
    classDef secrets fill:#d63384,color:#fff,stroke:#a02060,stroke-width:2px
    classDef net fill:#0d6efd,color:#fff,stroke:#0a58ca,stroke-width:2px
    classDef infra fill:#495057,color:#fff,stroke:#343a40,stroke-width:2px
    classDef offline fill:#6c757d,color:#fff,stroke:#495057,stroke-width:3px

    class RootCA offline
    class VaultHA,CertMgr pki
    class ESO secrets
    class KC,OAuth identity
    class Prom,Grafana,AM,Loki,Alloy,Hubble obs
    class ArgoCD,ArgoRO,ArgoWF,GitLabEE,Praefect,Runners,HarborCore cicd
    class CNPG_KC,CNPG_HB,CNPG_GL,RedisGL,ValkeyHB,MinIOShared data
    class CNPGOp,RedisOp infra
    class Traefik net
    class etcd,api,sched infra
```

---

## Data Flow Legend

| Color | Ecosystem | Components |
|-------|-----------|------------|
| Red | PKI &amp; Certificates | Root CA, Vault, cert-manager |
| Purple | Identity &amp; Access | Keycloak, OAuth2-proxy |
| Orange | Observability | Prometheus, Grafana, Loki, Alloy, Hubble, Alertmanager |
| Green | CI/CD &amp; GitOps | GitLab, Runners, ArgoCD, Argo Rollouts, Argo Workflows |
| Cyan | Data &amp; Storage | CNPG (x3), Redis, Valkey, MinIO |
| Pink | Secrets &amp; Config | External Secrets Operator |
| Blue | Networking | Traefik (Gateway API) |
| Gray | Infrastructure | Controlplane, operators |

---

## Connection Types

| Line Style | Meaning |
|------------|---------|
| Solid arrow | Active data flow (runtime) |
| Dashed arrow | Lifecycle management or one-time operation |
| Label text | Protocol or relationship type |

---

## Deployment Bundle Sequence

Shows which bundle deploys each service and the strict dependency chain.

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
        b2_cnpg["CNPG (Keycloak)"]
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
        b4_cnpg["CNPG (Harbor)"]
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
        b6_cnpg["CNPG (GitLab)"]
        b6_redis["Redis Sentinel"]
    end

    B1 --> B2 --> B3 --> B4 --> B5 --> B6

    classDef pki fill:#dc3545,color:#fff,stroke:#a02030,stroke-width:2px
    classDef identity fill:#6f42c1,color:#fff,stroke:#4a2a7f,stroke-width:2px
    classDef obs fill:#fd7e14,color:#fff,stroke:#b15810,stroke-width:2px
    classDef cicd fill:#198754,color:#fff,stroke:#0d5a32,stroke-width:2px
    classDef data fill:#0dcaf0,color:#000,stroke:#0a9db5,stroke-width:2px

    class b1_vault,b1_cm,b1_eso,b1_cnpg_op,b1_redis_op pki
    class b2_kc,b2_oauth,b2_cnpg identity
    class b3_prom,b3_graf,b3_loki,b3_alloy,b3_hub,b3_am obs
    class b4_harbor,b4_cnpg,b4_minio,b4_valkey data
    class b5_argo,b5_ro,b5_wf cicd
    class b6_gl,b6_run,b6_prae,b6_cnpg,b6_redis cicd
```

---

## Namespace Map

Shows how services are distributed across Kubernetes namespaces.

```mermaid
graph LR
    subgraph ns_vault["vault"]
        vault_svc["Vault HA (3-replica Raft)"]
    end

    subgraph ns_cm["cert-manager"]
        cm_svc["cert-manager (controller, webhook, cainjector)"]
    end

    subgraph ns_eso["external-secrets"]
        eso_svc["ESO (operator, webhook, cert-controller)"]
    end

    subgraph ns_cnpg["cnpg-system"]
        cnpg_op["CNPG Operator"]
    end

    subgraph ns_redis_op["redis-operator"]
        redis_op["Redis Operator"]
    end

    subgraph ns_kc["keycloak"]
        kc_svc["Keycloak (3-replica)"]
        oauth_svc["OAuth2-proxy (2-replica)"]
        kc_db["CNPG PostgreSQL (3-replica)"]
    end

    subgraph ns_mon["monitoring"]
        prom_svc["Prometheus (2-replica)"]
        graf_svc["Grafana (2-replica)"]
        am_svc["Alertmanager (2-replica)"]
        loki_svc["Loki (2-replica)"]
        alloy_svc["Alloy (DaemonSet)"]
    end

    subgraph ns_cilium["cilium"]
        hubble_svc["Hubble (DaemonSet + Relay)"]
    end

    subgraph ns_harbor["harbor"]
        harbor_svc["Harbor (2-replica)"]
        harbor_db["CNPG PostgreSQL (3-replica)"]
        valkey_svc["Valkey Sentinel (3-node)"]
    end

    subgraph ns_minio["minio"]
        minio_svc["MinIO (shared)"]
    end

    subgraph ns_argo["argocd"]
        argo_svc["ArgoCD (3-replica)"]
    end

    subgraph ns_aro["argo-rollouts"]
        aro_svc["Argo Rollouts (2-replica)"]
    end

    subgraph ns_awf["argo-workflows"]
        awf_svc["Argo Workflows (2-replica)"]
    end

    subgraph ns_gl["gitlab"]
        gl_svc["GitLab EE (3-replica)"]
        gl_prae["Praefect (3) + Gitaly (3)"]
        gl_db["CNPG PostgreSQL (3-replica)"]
        gl_redis["Redis Sentinel (3-node)"]
    end

    subgraph ns_run["gitlab-runners"]
        run_svc["GitLab Runners (HPA)"]
    end

    classDef pki fill:#dc3545,color:#fff,stroke:#a02030
    classDef identity fill:#6f42c1,color:#fff,stroke:#4a2a7f
    classDef obs fill:#fd7e14,color:#fff,stroke:#b15810
    classDef cicd fill:#198754,color:#fff,stroke:#0d5a32
    classDef data fill:#0dcaf0,color:#000,stroke:#0a9db5
    classDef secrets fill:#d63384,color:#fff,stroke:#a02060
    classDef net fill:#0d6efd,color:#fff,stroke:#0a58ca

    class vault_svc,cm_svc pki
    class eso_svc secrets
    class cnpg_op,redis_op data
    class kc_svc,oauth_svc identity
    class kc_db,harbor_db,gl_db,gl_redis,valkey_svc,minio_svc data
    class prom_svc,graf_svc,am_svc,loki_svc,alloy_svc,hubble_svc obs
    class harbor_svc,argo_svc,aro_svc,awf_svc,gl_svc,gl_prae,run_svc cicd
```

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
