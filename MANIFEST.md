# Platform Manifest

Bundle version: **2.1.17**

All Helm charts are cached in Harbor OCI registry (`harbor.example.com`).
All container images are pulled through Harbor pull-through cache.

## Helm Charts

| Chart | Version | Upstream Source | Bundle Group |
|-------|---------|----------------|--------------|
| cert-manager | v1.19.4 | <https://charts.jetstack.io> | 05-pki-secrets |
| vault | 0.32.0 | <https://helm.releases.hashicorp.com> | 05-pki-secrets |
| external-secrets | 2.0.1 | <https://charts.external-secrets.io> | 05-pki-secrets |
| cloudnative-pg | 0.27.1 | <https://cloudnative-pg.github.io/charts> | 00-operators |
| redis-operator | 0.23.0 | <https://ot-container-kit.github.io/helm-charts> | 00-operators |
| external-dns | 1.16.1 | <https://kubernetes-sigs.github.io/external-dns> | 15-dns |
| prometheus-operator-crds | 27.0.0 | <https://prometheus-community.github.io/helm-charts> | 00-operators |
| kube-prometheus-stack | 82.10.0 | <https://prometheus-community.github.io/helm-charts> | 20-monitoring |
| harbor | 1.18.2 | <https://helm.goharbor.io> | 30-harbor |
| argo-cd | 9.4.7 | `oci://ghcr.io/argoproj/argo-helm/argo-cd` | 40-gitops |
| argo-rollouts | 2.40.6 | `oci://ghcr.io/argoproj/argo-helm/argo-rollouts` | 40-gitops |
| argo-workflows | 0.47.4 | `oci://ghcr.io/argoproj/argo-helm/argo-workflows` | 40-gitops |
| gitlab | 9.9.2 | <https://charts.gitlab.io> | 50-gitlab |
| gitlab-runner | 0.86.0 | <https://charts.gitlab.io> | 50-gitlab |

## Container Images

| Image | Tag | Used By |
|-------|-----|---------|
| docker.io/alpine/k8s | 1.32.4 | Init jobs (kubectl/helm operations) |
| curlimages/curl | 8.12.1 | Init jobs (health checks, API calls) |
| quay.io/keycloak/keycloak | 26.0.8 | Keycloak identity provider |
| ghcr.io/cloudnative-pg/postgresql | 17.6 | CNPG clusters (Harbor, GitLab) |
| ghcr.io/cloudnative-pg/postgresql | 16.6 | CNPG clusters (Keycloak, Grafana) |
| quay.io/opstree/redis | v7.0.15 | Redis operator managed instances |
| quay.io/opstree/redis-sentinel | v7.0.15 | Redis Sentinel (HA) |
| oliver006/redis_exporter | v1.66.0 | Redis Prometheus metrics exporter |
| quay.io/minio/minio | RELEASE.2024-11-07T00-52-20Z | MinIO object storage |
| quay.io/minio/mc | RELEASE.2025-08-13T08-35-41Z | MinIO client (init jobs) |
| docker.io/grafana/loki | 3.4.6 | Loki log aggregation |
| docker.io/grafana/alloy | v1.6.1 | Alloy telemetry collector |
| quay.io/oauth2-proxy/oauth2-proxy | v7.8.1 | OAuth2 proxy (Keycloak OIDC) |
| harbor.example.com/library/node-labeler | v0.2.0 | Automatic node labeling |
| harbor.example.com/library/storage-autoscaler | v0.2.0 | PVC volume autoscaling |
| registry.k8s.io/autoscaling/cluster-autoscaler | v1.34.3 | Cluster autoscaler |
| hashicorp/vault | 1.21.2 | Vault secrets management (HA Raft) |
| valkey/valkey | 8-alpine | Valkey (Harbor cache) |
| docker.io/library/haproxy | 2.9.4-alpine | HAProxy (Valkey Sentinel proxy) |

## Custom Resource Definitions

### Installed via Helm Charts

These CRDs are installed automatically by their respective Helm charts:

| CRD Group | Installed By | Bundle Group |
|-----------|-------------|--------------|
| `cert-manager.io` | cert-manager chart | 05-pki-secrets |
| `external-secrets.io` | external-secrets chart | 05-pki-secrets |
| `postgresql.cnpg.io` | cloudnative-pg chart | 00-operators |
| `redis.redis.opstreelabs.in` | redis-operator chart | 00-operators |
| `monitoring.coreos.com` | prometheus-operator-crds chart | 00-operators |
| `argoproj.io` (Application, AppProject) | argo-cd chart | 40-gitops |
| `argoproj.io` (Rollout, AnalysisTemplate) | argo-rollouts chart | 40-gitops |
| `argoproj.io` (Workflow, CronWorkflow) | argo-workflows chart | 40-gitops |

### Installed via Raw Manifests

These CRDs are applied directly as YAML manifests:

| CRD | API Group | Bundle |
|-----|-----------|--------|
| `tcproutes.gateway.networking.k8s.io` | gateway.networking.k8s.io | 00-operators/gateway-api-crds |
| `tlsroutes.gateway.networking.k8s.io` | gateway.networking.k8s.io | 00-operators/gateway-api-crds |
| `udproutes.gateway.networking.k8s.io` | gateway.networking.k8s.io | 00-operators/gateway-api-crds |
| `volumeautoscalers.autoscaling.volume-autoscaler.io` | autoscaling.volume-autoscaler.io | 00-operators/storage-autoscaler |

### Pre-installed on Cluster

These CRDs are provided by the RKE2 cluster or Rancher and are not managed by this repo:

| CRD Group | Provided By |
|-----------|-------------|
| `gateway.networking.k8s.io` (standard channel) | RKE2 / Traefik |
| `cilium.io` | Cilium CNI (RKE2 system chart) |
| `fleet.cattle.io` | Rancher Fleet |
| `management.cattle.io` | Rancher |

## Bundle Groups

| Group | Bundles | Description |
|-------|---------|-------------|
| 00-operators | 7 | CNPG, Redis operator, node-labeler, storage-autoscaler, cluster-autoscaler, prometheus-crds, gateway-api-crds |
| 05-pki-secrets | 8 | Vault (HA), cert-manager, ESO, vault-init, vault-unsealer, vault-pki-issuer, vault-bootstrap-store |
| 10-identity | 4 | Keycloak, CNPG (Keycloak DB), keycloak-config |
| 15-dns | 2 | external-dns, external-dns-secrets |
| 20-monitoring | 7 | Prometheus stack, Grafana, Loki, Alloy, monitoring-init, monitoring-secrets, ingress-auth |
| 30-harbor | 7 | Harbor, MinIO, Valkey, CNPG (Harbor DB), harbor-init, harbor-manifests, harbor-secrets |
| 40-gitops | 11 | ArgoCD, Argo Rollouts, Argo Workflows, init jobs, manifests, credentials, analysis-templates |
| 50-gitlab | 10 | GitLab core, CNPG, Redis, runners (shared + terraform), init jobs, credentials |

**Source of truth:** `fleet-gitops/.env`
