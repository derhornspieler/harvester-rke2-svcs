# Argo GitOps Suite

Deploys the complete Argo GitOps stack across three dedicated namespaces:

| Component | Namespace | URL | Auth |
|-----------|-----------|-----|------|
| ArgoCD | `argocd` | `https://argo.example.com` | Native OIDC (Keycloak) |
| Argo Rollouts | `argo-rollouts` | `https://rollouts.example.com` | Basic-auth (initial), OAuth2-proxy (future) |
| Argo Workflows | `argo-workflows` | `https://workflows.example.com` | Basic-auth (initial) |

## Architecture

```
                        Traefik (Gateway API)
                       /          |          \
             argo.example.com  rollouts.example.com  workflows.example.com
                  |                   |                      |
             ArgoCD Server     Rollouts Dashboard    Workflows Server
             (HA, 2 replicas)  (1 replica)           (1 replica)
                  |                   |
             ArgoCD Controller Rollouts Controller
             (2 replicas)      (HA, 2 replicas)
                  |
             Repo Server (HA, 2 replicas)
             ApplicationSet (2 replicas)
                  |
             Valkey (redis-ha, 3 replicas + HAProxy)
```

### ArgoCD

Deployed in HA mode with the `redis-ha` subchart providing a 3-node Valkey (Redis-compatible) cluster with HAProxy and Sentinel. Key components:

- **Application Controller** (2 replicas): reconciles Application resources
- **Server** (2-5 replicas, HPA): API and web UI, TLS terminated at Traefik
- **Repo Server** (2-5 replicas, HPA): clones Git repos and generates manifests
- **ApplicationSet Controller** (2 replicas): generates Applications from templates
- **Dex**: disabled (native OIDC via Keycloak configured at runtime by `setup-keycloak.sh`)
- **Notifications**: disabled

### Argo Rollouts

HA controller with the Gateway API traffic router plugin for progressive delivery (canary and blue-green deployments):

- **Controller** (2 replicas): manages Rollout resources and traffic shifting
- **Dashboard** (1 replica): web UI at `rollouts.example.com`
- **Gateway API Plugin**: configurable via `ARGO_ROLLOUTS_PLUGIN_URL` env var, used to manipulate HTTPRoute weights during canary rollouts
- **OAuth2-proxy**: pre-deployed for future OIDC integration (Keycloak); initial access uses basic-auth

### Argo Workflows

Lightweight workflow engine for CI/CD pipelines and automation tasks:

- **Controller** (1 replica): orchestrates Workflow execution
- **Server** (1 replica): API and web UI at `workflows.example.com`, `--auth-mode=server`
- Access protected by basic-auth via Traefik middleware

## AnalysisTemplates

Three `ClusterAnalysisTemplate` resources are deployed for use with Argo Rollouts progressive delivery:

| Template | Metric | Default Threshold | Query Window |
|----------|--------|-------------------|--------------|
| `success-rate` | HTTP 2xx ratio | >= 98% | 2m rate, 5 samples |
| `latency-check` | p99 latency (ms) | < 500ms | 2m rate, 5 samples |
| `error-rate` | HTTP 5xx ratio | < 2% | 2m rate, 5 samples |

All templates query Prometheus at `kube-prometheus-stack-prometheus.monitoring.svc:9090` and accept `service-name`, `namespace`, and threshold arguments.

## Deployment

```bash
scripts/deploy-argo.sh
```

Deploy phases:

1. Create namespaces (`argocd`, `argo-rollouts`, `argo-workflows`)
2. Deploy ExternalSecrets (Vault-synced OAuth2-proxy and Redis credentials)
3. Helm install ArgoCD (HA with redis-ha subchart)
4. Helm install Argo Rollouts and Argo Workflows
5. Deploy Gateways, HTTPRoutes, basic-auth middleware, and OAuth2-proxy
6. Deploy ClusterAnalysisTemplates and monitoring (ServiceMonitors, dashboards, alerts)
7. Verify all components healthy

## Authentication Model

### ArgoCD -- Native OIDC

ArgoCD uses its built-in OIDC integration with Keycloak. The `setup-keycloak.sh` post-deploy script creates the OIDC client and configures ArgoCD's `argocd-cm` ConfigMap with the issuer URL, client ID, and CA trust. No separate OAuth2-proxy is needed.

Initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

### Argo Rollouts -- Basic-auth (initial)

The Rollouts dashboard is protected by Traefik basic-auth middleware (`basic-auth-rollouts` secret in `argo-rollouts` namespace). The `ARGO_BASIC_AUTH_PASS` env var sets the password.

An OAuth2-proxy instance and ForwardAuth middleware are pre-deployed for future migration to OIDC. To switch, update the HTTPRoute filter from `basic-auth-rollouts` to `oauth2-proxy-rollouts`.

### Argo Workflows -- Basic-auth (initial)

The Workflows server is protected by Traefik basic-auth middleware (`basic-auth-workflows` secret in `argo-workflows` namespace). The `WORKFLOWS_BASIC_AUTH_PASS` env var sets the password.

## Monitoring

### ServiceMonitors

| Monitor | Namespace Scraped | Selector |
|---------|-------------------|----------|
| `argocd` | `argocd` | All `argocd-*-metrics` services |
| `argo-rollouts` | `argo-rollouts` | `app.kubernetes.io/component: rollouts-controller` |
| `argo-workflows` | `argo-workflows` | `app.kubernetes.io/name: argo-workflows-workflow-controller` |

### Grafana Dashboards

Three Grafana dashboards are deployed as ConfigMaps in the `monitoring` namespace:

- **ArgoCD**: application sync status, health, controller reconciliation, API server latency
- **Argo Rollouts**: rollout progress, analysis run results, traffic weight shifts
- **Argo Workflows**: workflow completion rates, duration, queue depth

### Alerts

Defined in `monitoring/argocd-alerts.yaml` (PrometheusRule):

| Alert | Severity | Condition |
|-------|----------|-----------|
| `ArgoCDDown` | critical | Any ArgoCD component unreachable for 5m |
| `ArgoCDAppOutOfSync` | warning | Application out of sync for 15m |
| `ArgoCDAppDegraded` | warning | Application health Degraded/Missing for 10m |
| `ArgoRolloutsDown` | warning | Rollouts controller unreachable for 5m |

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `ARGO_BASIC_AUTH_PASS` | Yes | Password for Rollouts dashboard basic-auth |
| `WORKFLOWS_BASIC_AUTH_PASS` | Yes | Password for Workflows server basic-auth |
| `HELM_CHART_ARGOCD` | No | Override ArgoCD Helm chart source (OCI) |
| `HELM_CHART_ROLLOUTS` | No | Override Argo Rollouts Helm chart source (OCI) |
| `HELM_CHART_WORKFLOWS` | No | Override Argo Workflows Helm chart source (OCI) |
| `ARGO_ROLLOUTS_PLUGIN_URL` | No | Gateway API traffic router plugin binary URL |

## File Structure

```
services/argo/
  kustomization.yaml
  MANIFEST.yaml
  README.md
  argocd/
    namespace.yaml
    argocd-values.yaml
    gateway.yaml
    httproute.yaml
  argo-rollouts/
    namespace.yaml
    argo-rollouts-values.yaml
    gateway.yaml
    httproute.yaml
    middleware-basic-auth.yaml
    middleware-oauth2-proxy.yaml
    oauth2-proxy.yaml
    external-secret-oauth2-proxy.yaml
    external-secret-redis.yaml
  argo-workflows/
    namespace.yaml
    argo-workflows-values.yaml
    gateway.yaml
    httproute.yaml
    middleware-basic-auth.yaml
  analysis-templates/
    success-rate.yaml
    latency-check.yaml
    error-rate.yaml
  monitoring/
    kustomization.yaml
    service-monitor-argocd.yaml
    service-monitor-argo-rollouts.yaml
    service-monitor-argo-workflows.yaml
    configmap-dashboard-argocd.yaml
    configmap-dashboard-argo-rollouts.yaml
    configmap-dashboard-argo-workflows.yaml
    argocd-alerts.yaml
```
