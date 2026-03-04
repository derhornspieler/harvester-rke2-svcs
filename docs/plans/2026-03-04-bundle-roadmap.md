# Service Bundle Roadmap

**Goal:** Deploy a full enterprise CI/CD + GitOps platform on RKE2.

**Scope:** Bootstrap and deploy services only. ArgoCD-to-GitLab handoff and CI/CD integration is a separate future roadmap.

**Conventions:**
- All services use Gateway API + Traefik for ingress (HTTP/HTTPS)
- TLS via cert-manager gateway-shim (`cert-manager.io/cluster-issuer: vault-issuer`)
- Secrets via ESO + Vault KV v2
- Each bundle has a deploy script for bootstrap, ArgoCD manages steady-state later
- GitLab SSH uses TCP Gateway listener (port 22 passthrough)

---

## Bundle 1: PKI & Secrets (DONE)

| Service | Version | Purpose |
|---------|---------|---------|
| Vault | 1.21.2 (chart 0.32.0) | Secrets management, PKI intermediate CA |
| cert-manager | v1.19.4 | TLS certificate automation via Vault PKI |
| ESO | v2.0.1 | Sync Vault secrets to K8s Secrets |

---

## Bundle 2: Monitoring

| Service | Purpose |
|---------|---------|
| Prometheus (kube-prometheus-stack) | Metrics collection, alerting |
| Grafana | Dashboards (includes dashboards from source repo) |
| Loki | Log aggregation |
| Alloy (Grafana Agent) | Log/metric shipping |

Depends on: Bundle 1 (TLS, secrets)

---

## Bundle 3: Harbor

| Service | Purpose |
|---------|---------|
| Harbor | Container registry + pull-through cache |
| MinIO | S3-compatible object storage for Harbor |
| CNPG (PostgreSQL) | Harbor database |
| Valkey | Harbor caching layer |

Depends on: Bundle 1 (TLS, secrets), Bundle 2 (monitoring)

---

## Bundle 4: Identity

| Service | Purpose |
|---------|---------|
| Keycloak | OIDC provider, single realm, group-based RBAC |
| OAuth2-proxy | Auth proxy for non-OIDC services (Hubble, etc.) |

**Identity model:**
- Single realm: `platform`
- Bootstrap user: `admin-breakglass` (group: `platform-admins`, access: all clients)
- Independent sessions: `prompt=login` on all clients
- Group-based access control per client
- Clients: Grafana, ArgoCD, Harbor, Hubble, GitLab, Argo Workflows, Keycloak admin

Depends on: Bundle 1 (TLS, secrets), Bundle 3 (CNPG for DB, Harbor for images)

---

## Bundle 5: GitOps & Workflows

| Service | Purpose |
|---------|---------|
| ArgoCD | GitOps engine (declarative service management) |
| Argo Rollouts | Blue/green and canary deployment strategies |
| Argo Workflows | Workflow automation, DAG-based pipelines |

Depends on: Bundle 1 (TLS, secrets), optionally Bundle 4 (SSO)

---

## Bundle 6: Git & CI

| Service | Purpose |
|---------|---------|
| GitLab (Ultimate) | Self-hosted Git server, licensed via registration key |
| GitLab Runners | Kubernetes executor (CI jobs run as pods) |
| CNPG (PostgreSQL) | GitLab database |
| Valkey | GitLab caching/session store |

**Notes:**
- Ultimate license via registration key file (gitignored, from source repo)
- Runners use K8s executor (fresh pod per job, auto-cleanup)
- GitLab SSH via TCP Gateway listener (port 22 passthrough)
- Post-deploy research: GitLab Auto DevOps / Review Apps on K8s

Depends on: Bundle 1 (TLS, secrets), Bundle 3 (Harbor for images), Bundle 4 (SSO)

---

## Dependency Graph

```
Bundle 1: PKI & Secrets (DONE)
    │
    ├── Bundle 2: Monitoring
    │       │
    │       └── Bundle 3: Harbor
    │               │
    │               ├── Bundle 4: Identity
    │               │       │
    │               │       ├── Bundle 5: GitOps & Workflows
    │               │       │
    │               │       └── Bundle 6: Git & CI
    │               │
    │               └── Bundle 5: GitOps & Workflows (can deploy without Identity)
    │
    └── Bundle 5: GitOps & Workflows (minimal, without SSO)
```

## Out of Scope (Future Roadmap)

- ArgoCD reconfigured to pull from GitLab (post-Bundle 6)
- CI/CD pipeline integration (GitLab CI → Harbor → ArgoCD deploy)
- GitLab Auto DevOps / Review Apps research
- Additional Keycloak realms, users, and RBAC policies
