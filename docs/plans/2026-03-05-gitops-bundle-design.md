# GitOps & Workflows Bundle Design

**Date:** 2026-03-05
**Status:** Approved
**Bundle:** 5 of 6

## Overview

Deploy ArgoCD (HA), Argo Rollouts (HA + dashboard), and Argo Workflows as the GitOps and progressive delivery platform. Includes Prometheus-driven AnalysisTemplates for automated blue/green promotion.

## Services

| Service | Helm Chart | Purpose |
|---------|-----------|---------|
| ArgoCD | argo/argo-cd | GitOps engine, declarative service management |
| Argo Rollouts | argo/argo-rollouts | Progressive delivery (blue/green, canary) |
| Argo Workflows | argo/argo-workflows | Workflow/DAG orchestration |

## Architecture

```
ArgoCD (argo.<domain>) ← Native OIDC via Keycloak
  ├── Server (2-5 replicas, HPA)
  ├── Controller (2 replicas)
  ├── Repo-Server (2-5 replicas, HPA)
  ├── ApplicationSet Controller (2 replicas)
  └── Redis HA (Valkey 3+3 with HAProxy)

Argo Rollouts (rollouts.<domain>) ← basic-auth initially, OAuth2-proxy later
  ├── Controller (2 replicas)
  └── Dashboard (1 replica)

Argo Workflows (workflows.<domain>) ← basic-auth initially, OAuth2-proxy later
  ├── Controller (1 replica)
  └── Server (1 replica)

AnalysisTemplates → Prometheus queries for automated promotion:
  - success-rate (HTTP 2xx >= 98%)
  - latency-check (P99 < 500ms)
  - error-rate (HTTP 5xx < 2%)
```

## Directory Structure

```
services/argo/
├── kustomization.yaml
├── argocd/
│   ├── namespace.yaml
│   ├── argocd-values.yaml
│   ├── gateway.yaml                    # argo.<domain>
│   └── httproute.yaml                  # Direct to argocd-server (native OIDC)
├── argo-rollouts/
│   ├── namespace.yaml
│   ├── argo-rollouts-values.yaml
│   ├── gateway.yaml                    # rollouts.<domain>
│   ├── httproute.yaml                  # basic-auth middleware
│   ├── basic-auth-middleware.yaml      # Traefik basic-auth (placeholder)
│   ├── oauth2-proxy.yaml              # ForwardAuth (activated later)
│   ├── middleware-oauth2-proxy.yaml    # Traefik ForwardAuth (activated later)
│   ├── external-secret-oauth2-proxy.yaml
│   └── external-secret-redis.yaml
├── argo-workflows/
│   ├── namespace.yaml
│   ├── argo-workflows-values.yaml
│   ├── gateway.yaml                    # workflows.<domain>
│   ├── httproute.yaml                  # basic-auth middleware
│   └── basic-auth-middleware.yaml      # Traefik basic-auth (placeholder)
├── analysis-templates/
│   ├── success-rate.yaml
│   ├── latency-check.yaml
│   └── error-rate.yaml
├── monitoring/
│   ├── kustomization.yaml
│   ├── service-monitor-argocd.yaml
│   ├── service-monitor-argo-rollouts.yaml
│   ├── service-monitor-argo-workflows.yaml
│   ├── configmap-dashboard-argocd.yaml
│   ├── configmap-dashboard-argo-rollouts.yaml
│   ├── configmap-dashboard-argo-workflows.yaml
│   └── argocd-alerts.yaml
├── MANIFEST.yaml
└── README.md
```

## Deploy Script (scripts/deploy-argo.sh) — 7 Phases

| Phase | Component | What Happens |
|-------|-----------|--------------|
| 1 | Namespaces | Create argocd, argo-rollouts, argo-workflows |
| 2 | ESO | SecretStores for each namespace |
| 3 | ArgoCD | Helm install (HA, Redis, --insecure), wait for server |
| 4 | Argo Rollouts | Helm install (HA controller + dashboard), wait for controller |
| 5 | Argo Workflows | Helm install, wait for controller |
| 6 | Ingress + Auth | Gateways, HTTPRoutes, basic-auth secrets, AnalysisTemplates |
| 7 | Monitoring + Verify | Apply monitoring, verify TLS certs, health checks |

## Auth Model

| Service | URL | Auth (Bundle 5) | Auth (After Keycloak config) |
|---------|-----|-----------------|------------------------------|
| ArgoCD | `argo.<domain>` | Native OIDC (Keycloak) | Same (already OIDC) |
| Rollouts | `rollouts.<domain>` | Traefik basic-auth | OAuth2-proxy (Keycloak) |
| Workflows | `workflows.<domain>` | Traefik basic-auth | OAuth2-proxy (Keycloak) |

ArgoCD's OIDC config is set in the Helm values pointing to Keycloak. The `argocd` OIDC client must exist in Keycloak (created by setup-keycloak.sh or manually).

Rollouts and Workflows start with basic-auth. OAuth2-proxy manifests are included but not activated until Keycloak clients are created.

## Resource Conventions

- **Requests only, no limits**
- **HPA:** ArgoCD server (2-5), repo-server (2-5) at 70% CPU
- **Anti-affinity:** All ArgoCD components, Rollouts controller, Redis replicas
- **Node selectors:** All on `workload-type: general`

## AnalysisTemplates (ClusterAnalysisTemplate)

| Template | Metric | Default Threshold | Window |
|----------|--------|------------------|--------|
| success-rate | HTTP 2xx / total | >= 98% | 5 × 30s (150s) |
| latency-check | P99 latency | < 500ms | 5 × 30s |
| error-rate | HTTP 5xx / total | < 2% | 5 × 30s |

Used by Argo Rollouts for automated blue/green pre-promotion analysis. Queries Prometheus.

## Dependencies

- Bundle 1 (PKI & Secrets): TLS, Vault, ESO
- Bundle 2 (Identity): Keycloak for ArgoCD OIDC (must have `argocd` client created)
- Bundle 3 (Monitoring): Prometheus for AnalysisTemplates and ServiceMonitors

## Out of Scope (Future)

- ArgoCD RBAC (AppProjects, group-to-role mapping) — configured post-deploy
- ApplicationSet for GitLab auto-discovery — requires Bundle 6 (GitLab)
- App-of-apps bootstrap pattern — configured after GitLab is running
