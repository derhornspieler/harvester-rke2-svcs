# Service Bundle Roadmap

**Goal:** Deploy a full enterprise CI/CD + GitOps platform on RKE2.

**Scope:** Bootstrap and deploy services only. ArgoCD-to-GitLab handoff and CI/CD integration is a separate future roadmap.

**Conventions:**
- All services use Gateway API + Traefik for ingress (HTTP/HTTPS)
- TLS via cert-manager gateway-shim (`cert-manager.io/cluster-issuer: vault-issuer`)
- Secrets via ESO + Vault KV v2
- Each bundle has a deploy script for bootstrap, ArgoCD manages steady-state later
- GitLab SSH uses TCP Gateway listener (port 22 passthrough)
- **NetworkPolicies** on all namespaces — default-deny-ingress + explicit allow rules (applied in final phase of each bundle)
- **Resource requests only, no limits** — allows bursting, prevents artificial OOM kills
- **HPA enabled** on stateless workloads (Grafana, OAuth2-proxy, ArgoCD server, GitLab Webservice, etc.)
- **Storage autoscaler** on PVCs that grow (Prometheus TSDB, Loki, Gitaly, MinIO, CNPG WAL)
- **Pod anti-affinity** on all replicated workloads — spread across nodes (`topologyKey: kubernetes.io/hostname`)
- **Node selectors** — stateful on `workload-type: database`, general on `workload-type: general`

---

## Bundle 1: PKI & Secrets (DONE)

| Service | Version | Purpose |
|---------|---------|---------|
| Vault | 1.21.2 (chart 0.32.0) | Secrets management, PKI intermediate CA |
| cert-manager | v1.19.4 | TLS certificate automation via Vault PKI |
| ESO | v2.0.1 | Sync Vault secrets to K8s Secrets |

---

## Bundle 2: Identity

| Service | Purpose |
|---------|---------|
| CNPG operator | Auto-installed for PostgreSQL HA (Keycloak, Harbor, GitLab) |
| Shared MinIO | Auto-deployed for object storage (used by Harbor, GitLab backups) |
| Keycloak | OIDC provider, single realm, group-based RBAC |
| OAuth2-proxy | Auth proxy for non-OIDC services (Prometheus, Alertmanager, Hubble) |

**Identity model:**
- Single realm: `platform`
- Bootstrap user: `admin-breakglass` (group: `platform-admins`, access: all clients)
- Independent sessions: `prompt=login` on all clients
- Group-based access control per client
- Clients: Grafana, ArgoCD, Harbor, Hubble, GitLab, Argo Workflows, Keycloak admin

**Shared Infrastructure:**
- CNPG operator installed in Phase 1 (used by Bundles 2, 4, 6 for PostgreSQL)
- Shared MinIO deployed in Phase 1 (used by Harbor, GitLab backups)

Depends on: Bundle 1 (TLS, secrets)

---

## Bundle 3: Monitoring

| Service | Purpose |
|---------|---------|
| Prometheus (kube-prometheus-stack) | Metrics collection, alerting |
| Grafana | Dashboards (includes dashboards from source repo), native OIDC |
| Loki | Log aggregation |
| Alloy (Grafana Agent) | Log/metric shipping |
| NetworkPolicy | Default-deny-ingress, allows Traefik and Prometheus scraping |

Depends on: Bundle 1 (TLS, secrets)
- Optional: Bundle 2 (Identity) for OIDC pre-configuration in Grafana

---

## Bundle 4: Harbor

| Service | Purpose |
|---------|---------|
| Harbor | Container registry + pull-through cache |
| MinIO | S3-compatible object storage for Harbor (skip if already deployed in Bundle 2) |
| CNPG (PostgreSQL) | Harbor database (uses operator from Bundle 2) |
| Valkey | Harbor caching layer |
| NetworkPolicy | Default-deny-ingress, allows Traefik, Prometheus scraping |

Depends on: Bundle 1 (TLS, secrets), Bundle 2 (Identity for OIDC, CNPG operator, shared MinIO)

---

## Bundle 5: GitOps & Workflows

| Service | Purpose |
|---------|---------|
| ArgoCD | GitOps engine (declarative service management), OIDC SSO |
| Argo Rollouts | Blue/green and canary deployment strategies, analysis templates |
| Argo Workflows | Workflow automation, DAG-based pipelines |
| NetworkPolicy | Default-deny-ingress, allows Traefik, Prometheus scraping |

Depends on: Bundle 1 (TLS, secrets), Bundle 2 (Identity for OIDC), Bundle 3 (Monitoring for AnalysisTemplate queries)

---

## Bundle 6: Git & CI

| Service | Purpose |
|---------|---------|
| GitLab (Ultimate) | Self-hosted Git server, licensed via registration key |
| Praefect/Gitaly | Git repository storage with HA routing |
| GitLab Runners | Kubernetes executor (CI jobs run as pods) |
| CNPG (PostgreSQL) | GitLab database (uses operator from Bundle 2) |
| Redis Sentinel | GitLab caching/session/queue store |
| NetworkPolicy | Default-deny-ingress, allows Traefik, Prometheus scraping, SSH on port 22 |

**Notes:**
- Ultimate license via registration key file (gitignored, from source repo)
- Runners use K8s executor (fresh pod per job, auto-cleanup)
- GitLab SSH via TCP Gateway listener (port 22 passthrough)
- Post-deploy research: GitLab Auto DevOps / Review Apps on K8s

Depends on: Bundle 1 (TLS, secrets), Bundle 2 (Identity for OIDC, CNPG operator), Bundle 3 (Monitoring for ServiceMonitors), Bundle 4 (Harbor for Runner images)

---

## Dependency Graph

```
Bundle 1: PKI & Secrets (7 phases)
    ├─ CNPG operator (not yet)
    ├─ Vault intermediate CA
    ├─ TLS via cert-manager
    └─ Secrets via ESO + Vault KV v2
    │
    └── Bundle 2: Identity (8+6 phases) — installs CNPG operator + MinIO
            ├─ Keycloak OIDC provider
            ├─ CNPG operator (for all future PostgreSQL)
            ├─ Shared MinIO (for Harbor, GitLab backups)
            └─ OAuth2-proxy (for Prometheus, Alertmanager)
            │
            ├── Bundle 3: Monitoring (6 phases)
            │       ├─ Prometheus + Grafana (OIDC ready)
            │       ├─ Loki + Alloy (log pipeline)
            │       └─ Alertmanager (with OAuth2-proxy)
            │       │
            │       ├── Bundle 5: GitOps (7 phases) — needs Monitoring for analysis
            │       │       ├─ ArgoCD (OIDC + ServiceMonitors)
            │       │       ├─ Argo Rollouts (analysis templates)
            │       │       └─ Argo Workflows
            │       │
            │       └── Bundle 4: Harbor (8 phases) — can follow or precede Bundle 5
            │               ├─ Harbor registry
            │               ├─ MinIO (skip if exists from Bundle 2)
            │               ├─ CNPG (reuses operator from Bundle 2)
            │               └─ Valkey Sentinel
            │               │
            │               └── Bundle 6: Git & CI (9 phases)
            │                       ├─ GitLab webservice + runners
            │                       ├─ Praefect/Gitaly
            │                       ├─ CNPG (reuses operator)
            │                       └─ Redis Sentinel
```

## Out of Scope (Future Roadmap)

- ArgoCD reconfigured to pull from GitLab (post-Bundle 6)
- CI/CD pipeline integration (GitLab CI → Harbor → ArgoCD deploy)
- GitLab Auto DevOps / Review Apps research
- Additional Keycloak realms, users, and RBAC policies
