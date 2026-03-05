# harvester-rke2-svcs

[![CI](https://github.com/<GITHUB_ORG>/harvester-rke2-svcs/actions/workflows/ci.yml/badge.svg)](https://github.com/<GITHUB_ORG>/harvester-rke2-svcs/actions/workflows/ci.yml) [![License](https://img.shields.io/badge/license-Apache%202.0-green)](LICENSE)

Platform services for RKE2 clusters. Deploys six service bundles covering
PKI/secrets management, monitoring, container registry, identity/SSO, GitOps,
and Git/CI -- providing a complete foundation for production workloads.

## Architecture

```mermaid
graph LR
    subgraph "Bundle 1: PKI &amp; Secrets"
        Root["Offline Root CA"]
        Vault["Vault<br/>(Intermediate CA + KV v2)"]
        CM["cert-manager"]
        ESO["ESO"]
    end

    subgraph "Bundle 2: Identity"
        KC["Keycloak"]
        OAuth["OAuth2-proxy"]
        CNPG2["CNPG (Keycloak)"]
    end

    subgraph "Bundle 3: Monitoring"
        Prom["Prometheus"]
        Graf["Grafana"]
        Loki["Loki"]
        Alloy["Alloy"]
    end

    subgraph "Bundle 4: Harbor"
        Harbor["Harbor"]
        MinIO["MinIO"]
        CNPG1["CNPG (Harbor)"]
        Valkey["Valkey"]
    end

    subgraph "Bundle 5: GitOps"
        Argo["ArgoCD"]
        Roll["Rollouts"]
        WF["Workflows"]
    end

    subgraph "Bundle 6: Git &amp; CI"
        GL["GitLab"]
        Gitaly["Praefect/Gitaly"]
        CNPG3["CNPG (GitLab)"]
        GLRedis["Redis"]
        Runners["Runners"]
    end

    Root -->|signs| Vault
    Vault -->|pki_int/sign| CM
    Vault -->|kv/data| ESO

    ESO -->|secrets| Harbor
    ESO -->|secrets| KC
    CM -->|TLS| Graf
    CM -->|TLS| Harbor
    CM -->|TLS| KC

    Alloy -->|logs| Loki
    Prom -->|scrapes| Vault
    Prom -->|scrapes| Harbor
    Prom -->|scrapes| KC

    KC -->|OIDC| OAuth
    KC -->|OIDC| Argo
    KC -->|OIDC| GL
    OAuth -->|protects| Prom
    OAuth -->|protects| Graf

    ESO -->|secrets| Argo
    ESO -->|secrets| GL
    CM -->|TLS| Argo
    CM -->|TLS| GL
    Prom -->|scrapes| Argo
    Prom -->|scrapes| GL

    GL --> Gitaly
    GL --> CNPG3
    GL --> GLRedis
    GL --> Runners

    style Root fill:#d32f2f,color:#fff
    style Vault fill:#f57c00,color:#fff
    style CM fill:#1565c0,color:#fff
    style ESO fill:#1565c0,color:#fff
    style Prom fill:#e65100,color:#fff
    style Graf fill:#f57c00,color:#fff
    style Loki fill:#f57c00,color:#fff
    style Alloy fill:#f57c00,color:#fff
    style Harbor fill:#1565c0,color:#fff
    style KC fill:#7b1fa2,color:#fff
    style OAuth fill:#7b1fa2,color:#fff
    style Argo fill:#ef6c00,color:#fff
    style Roll fill:#ef6c00,color:#fff
    style WF fill:#ef6c00,color:#fff
    style GL fill:#e65100,color:#fff
    style Gitaly fill:#e65100,color:#fff
    style CNPG3 fill:#388e3c,color:#fff
    style GLRedis fill:#d32f2f,color:#fff
    style Runners fill:#e65100,color:#fff
```

See [docs/architecture.md](docs/architecture.md) for detailed diagrams
covering the PKI hierarchy, deployment phases, and data flows.

## Quick Start

**Prerequisites:** `kubectl`, `helm`, `jq`, `openssl`, `htpasswd`, and
cluster-admin access to an RKE2 cluster.

```bash
# 1. Generate a Root CA (once)
cd services/pki
./generate-ca.sh root -o "My Organization" -d roots/
cd ../..

# 2. Configure environment
cp scripts/.env.example scripts/.env
# Edit scripts/.env: set DOMAIN, ROOT_CA_KEY, passwords

# 3. Deploy Bundle 1 -- PKI & Secrets
./scripts/deploy-pki-secrets.sh

# 4. Deploy Bundle 2 -- Identity (Keycloak + OAuth2-proxy)
./scripts/deploy-keycloak.sh
./scripts/setup-keycloak.sh    # Realm, OIDC clients, groups (post-deploy)

# 5. Deploy Bundle 3 -- Monitoring
./scripts/deploy-monitoring.sh

# 6. Deploy Bundle 4 -- Harbor
./scripts/deploy-harbor.sh

# 7. Deploy Bundle 5 -- GitOps (ArgoCD + Rollouts + Workflows)
./scripts/deploy-argo.sh

# 8. Deploy Bundle 6 -- Git & CI (GitLab + Runners)
./scripts/deploy-gitlab.sh
```

Each deploy script runs ordered, idempotent phases. See
[docs/getting-started.md](docs/getting-started.md) for the full step-by-step
guide including verification and troubleshooting.

## Service Bundles

| Bundle | Services | Status |
|--------|----------|--------|
| PKI & Secrets | Vault, cert-manager, ESO, PKI tooling | Active |
| Identity | Keycloak, OAuth2-proxy, CNPG PostgreSQL | Active |
| Monitoring | Prometheus, Grafana, Alertmanager, Loki, Alloy | Active |
| Harbor | Harbor registry, MinIO, CNPG PostgreSQL, Valkey Sentinel | Active |
| GitOps | ArgoCD, Argo Rollouts, Argo Workflows, AnalysisTemplates | Active |
| Git & CI | GitLab EE, Praefect/Gitaly, CNPG PostgreSQL, Redis Sentinel, Runners, CI Templates | Active |

## Structure

```
services/                    # One directory per service (Kustomize + Helm values)
  pki/                       # Offline Root CA generation tooling
  vault/                     # 3-replica HA Vault with Raft storage
  cert-manager/              # ClusterIssuer + RBAC for Vault PKI
  external-secrets/          # ESO controller configuration
  monitoring-stack/          # Prometheus, Grafana, Alertmanager, Loki, Alloy
    helm/                    # kube-prometheus-stack Helm values + scrape configs
    loki/                    # Loki StatefulSet (single-binary mode)
    alloy/                   # Grafana Alloy DaemonSet (log collection)
    grafana/                 # Dashboards, Gateway, HTTPRoute
    prometheus/              # Gateway, HTTPRoute, basic-auth middleware
    alertmanager/            # Gateway, HTTPRoute, basic-auth middleware
    prometheus-rules/        # PrometheusRules (alerts)
    service-monitors/        # ServiceMonitors (scrape targets)
  harbor/                    # Harbor container registry
    minio/                   # MinIO object storage (S3 backend)
    postgres/                # CNPG PostgreSQL HA cluster
    valkey/                  # Valkey Redis Sentinel (cache/session)
    monitoring/              # Dashboards, alerts, ServiceMonitors
  keycloak/                  # Keycloak identity provider
    keycloak/                # Deployment, services, HPA, RBAC
    postgres/                # CNPG PostgreSQL HA cluster
    oauth2-proxy/            # OAuth2-proxy instances + middleware
    monitoring/              # Dashboards, alerts, ServiceMonitors
  argo/                      # Argo GitOps platform
    argocd/                  # ArgoCD Helm values, Gateway, HTTPRoute
    argo-rollouts/           # Argo Rollouts Helm values, OAuth2-proxy, basic-auth
    argo-workflows/          # Argo Workflows Helm values, basic-auth
    analysis-templates/      # AnalysisTemplates (error-rate, latency, success-rate)
    monitoring/              # Dashboards, alerts, ServiceMonitors
  gitlab/                    # GitLab EE + CI platform
    gitaly/                  # Praefect/Gitaly ExternalSecret
    praefect/                # Praefect DB secret + token ExternalSecrets
    redis/                   # OpsTree RedisReplication + RedisSentinel
    oidc/                    # OIDC ExternalSecret for Keycloak SSO
    runners/                 # Shared, security, and group runner Helm values + RBAC
    ci-templates/            # Reusable CI pipeline templates (jobs + patterns)
    monitoring/              # Dashboards, alerts, ServiceMonitors
scripts/                     # Deploy scripts and utility modules
  deploy-pki-secrets.sh      # Bundle 1 orchestrator (7 phases)
  deploy-keycloak.sh         # Bundle 2 orchestrator (8 phases)
  setup-keycloak.sh          # Post-deploy Keycloak config via Admin API (6 phases)
  deploy-monitoring.sh       # Bundle 3 orchestrator (6 phases)
  deploy-harbor.sh           # Bundle 4 orchestrator (8 phases)
  deploy-argo.sh             # Bundle 5 orchestrator (7 phases)
  deploy-gitlab.sh           # Bundle 6 orchestrator (9 phases)
  .env.example               # Environment variable template
  utils/                     # Shell utility modules
    log.sh                   # Colored logging + phase timing
    helm.sh                  # Idempotent Helm operations
    vault.sh                 # Vault CLI via kubectl exec
    wait.sh                  # K8s readiness polling
    subst.sh                 # CHANGEME_* token substitution
    basic-auth.sh            # htpasswd-based basic-auth secret creation
docs/                        # Architecture and getting started guides
```

## Day-2 Operations

```bash
# Unseal Vault after pod restart
./scripts/deploy-pki-secrets.sh --unseal-only

# Health check all components
./scripts/deploy-pki-secrets.sh --validate
./scripts/deploy-monitoring.sh --validate
./scripts/deploy-harbor.sh --validate
./scripts/deploy-keycloak.sh --validate
./scripts/deploy-argo.sh --validate
./scripts/deploy-gitlab.sh --validate

# Re-run a single phase
./scripts/deploy-pki-secrets.sh --phase 5

# Resume from a specific phase
./scripts/deploy-pki-secrets.sh --from 3
```

## Documentation

- [Architecture Overview](docs/architecture.md) -- PKI hierarchy, monitoring
  pipeline, Harbor storage architecture, identity flow, GitOps platform, GitLab
  CI/CD architecture, deployment phases, and component relationships
- [Getting Started Guide](docs/getting-started.md) -- step-by-step deployment
  of all six bundles, verification, and troubleshooting
- [Contributing](CONTRIBUTING.md) -- how to add services, coding conventions,
  and PR process

## Requirements

- RKE2 cluster with kubeconfig access
- `kubectl`, `helm`, `jq`, `openssl`, `htpasswd`
- Root CA key (offline, for initial PKI setup only)
- CNPG operator installed (for Harbor, Keycloak, and GitLab PostgreSQL clusters)
- Redis operator installed (for Valkey Sentinel and GitLab Redis Sentinel)

## License

This project is licensed under the [Apache License 2.0](LICENSE).
