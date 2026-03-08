# Master Diagram Reference Guide

Use this guide when authoring the 7 ecosystem documents to ensure consistency with the master platform diagram in `overview.md`.

## Color Scheme (Mermaid style classes)

```
Security/PKI:        #dc3545 (red)
Identity:            #6f42c1 (purple)
Networking:          #0d6efd (blue)
CI/CD:               #198754 (green)
Observability:       #fd7e14 (orange)
Data/Storage:        #0dcaf0 (cyan)
Secrets/Config:      #d63384 (pink)
```

## Component Map by Ecosystem

### 1. Authentication & Identity (Purple)

- Keycloak (OIDC Provider)
- OAuth2-proxy (Service Protector)

### 2. Networking & Ingress (Blue)

- Traefik (API Gateway)
- Gateway API (HTTPRoutes & Middleware)

### 3. PKI & Certificates (Red)

- Offline Root CA (Air-gapped)
- Vault (Intermediate CA + KV Secrets)
- cert-manager (Leaf Certificate Issuer)

### 4. CI/CD Pipeline (Green)

- GitLab (Repository + CI/CD)
- GitLab Runners (Job Execution)
- Harbor (Container Registry)
- ArgoCD (Policy-Driven Deployment)
- Argo Rollouts (Progressive Delivery)

### 5. Observability & Monitoring (Orange)

- Prometheus (Metrics Collection)
- Grafana (Visualization & Dashboards)
- Loki (Log Aggregation)
- Alloy (Log Collector)
- Hubble (Network Observability)
- Alertmanager (Alert Routing)

### 6. Data & Storage (Cyan)

- CloudNativePG (3x PostgreSQL HA)
- Redis/Valkey Sentinel (Cache + Session)
- MinIO (S3-compatible Storage)

### 7. Secrets & Configuration (Pink)

- External Secrets Operator (Sync to Vault)
- SecretStores (Vault Integration)

## Data Flow Patterns in Master Diagram

### TLS Certificate Distribution

```
RootCA (offline) → Vault (signs) → cert-manager (issues) →
  Traefik, Grafana, Keycloak, Harbor, GitLab, ArgoCD
```

### Secrets Injection

```
Vault (KV v2) → ESO → SecretStore →
  GitLab, Keycloak, ArgoCD, Harbor
```

### Identity & Authorization

```
Keycloak (OIDC) → OAuth2-proxy →
  Prometheus (protected)
  Grafana (protected)
  ArgoCD (protected)

Keycloak (OIDC) →
  ArgoCD (direct)
  Grafana (direct)
  GitLab (direct)
```

### Observability Scrape Paths

```
Prometheus (scrapes all) →
  Keycloak, Harbor, GitLab, ArgoCD, CNPG, Redis
```

### Log Collection Pipeline

```
Alloy (all nodes) → Loki (aggregated) → Grafana (visualized)
Hubble (network) → Loki → Grafana
```

### CI/CD Execution Pipeline

```
GitLab → Runners (execute jobs) → Harbor (push images) → ArgoCD (deploy)
```

### Data Persistence
```
CNPG → GitLab, Keycloak, Harbor, ArgoCD
Redis → GitLab, Keycloak, Harbor
MinIO → Harbor (backend), GitLab (backups)
```

## Naming Conventions

Use these exact component names when creating ecosystem documents:

| Formal Name | Used In Diagrams | Kubernetes Component |
|---|---|---|
| Keycloak | Keycloak | keycloak/keycloak (deployment) |
| OAuth2-proxy | OAuth2-proxy | keycloak/oauth2-proxy (deployment) |
| Traefik | Traefik | kube-system/traefik (DaemonSet from RKE2) |
| Gateway API | Gateway API | kube-system (APIGroup) |
| Offline Root CA | Offline Root CA | N/A (file-based, offline) |
| Vault | Vault | vault/vault (StatefulSet) |
| cert-manager | cert-manager | cert-manager/cert-manager (deployment) |
| GitLab | GitLab EE | gitlab/gitlab (Helm release) |
| GitLab Runners | GitLab Runners | gitlab-runners/* (Helm releases) |
| Harbor | Harbor | harbor/harbor (Helm release) |
| ArgoCD | ArgoCD | argocd/argocd-* (deployments) |
| Argo Rollouts | Argo Rollouts | argo-rollouts/argo-rollouts (deployment) |
| Prometheus | Prometheus | monitoring/prometheus-* (StatefulSet) |
| Grafana | Grafana | monitoring/grafana (deployment) |
| Loki | Loki | monitoring/loki (StatefulSet) |
| Alloy | Alloy | monitoring/alloy (DaemonSet) |
| Alertmanager | Alertmanager | monitoring/alertmanager-* (StatefulSet) |
| Hubble | Hubble | cilium/hubble-* (DaemonSet/relay) |
| CloudNativePG | CloudNativePG | CNPG operator in keycloak/harbor/gitlab |
| Redis/Valkey Sentinel | Redis/Valkey Sentinel | harbor/valkey-* , gitlab/redis-* (StatefulSets) |
| MinIO | MinIO | harbor/minio (StatefulSet) |
| External Secrets Operator | ESO Controller | external-secrets/external-secrets-webhook |
| SecretStore | SecretStore | N/A (virtual, per-service CRD) |

## Cross-References Between Ecosystems

When writing each ecosystem document, reference these connections:

- **PKI ↔ Everyone**: Every service depends on cert-manager TLS and Vault secrets
- **Identity ↔ Networking**: OAuth2-proxy sits between Gateway and protected services
- **Identity ↔ CI/CD**: Keycloak provides OIDC for GitLab, ArgoCD
- **CI/CD ↔ Data**: GitLab/Harbor/ArgoCD all persist state in CNPG + Redis
- **Observability ↔ Everything**: Prometheus scrapes all services; Alloy collects logs from all nodes
- **Secrets ↔ Everything**: ESO syncs Vault credentials into all service namespaces

## MDN for Ecosystem Authors

Each ecosystem document should:
1. **Start with the leadership diagram** (top, color-coded box from master)
2. **Include the "story" one-liner** from the design doc
3. **Show technical flow details** (e.g., OIDC token exchange, cert renewal)
4. **List the 2-5 key services** in that ecosystem
5. **Explain how this ecosystem depends on earlier bundles**
6. **Cross-link** to related ecosystems (e.g., PKI ↔ Networking for TLS)
7. **Include operational notes** (rollback, scaling, troubleshooting)
