# Fleet GitOps — Deployment Manifest

Complete inventory of Helm charts, container images, CRDs, and raw bundles
required for deployment. All OCI paths derive from `HARBOR_HOST` in `.env`.

## OCI Registry Configuration

All artifacts are stored in a single OCI-compatible registry. Change
`HARBOR_HOST` in `.env` to redirect everything to a different server.

| Path Pattern | Purpose |
|---|---|
| `oci://${HARBOR_HOST}/helm/<chart>` | Helm charts (pushed by push-charts.sh) |
| `oci://${HARBOR_HOST}/fleet/<bundle>` | Raw manifest bundles (pushed by push-bundles.sh) |

## Helm Charts (16)

| Chart | Version Variable | Upstream Source | Deploy Namespace |
|---|---|---|---|
| prometheus-operator-crds | `CHART_VER_PROMETHEUS_CRDS` | `HELM_REPO_PROMETHEUS` | monitoring |
| cloudnative-pg | `CHART_VER_CNPG` | `HELM_REPO_CNPG` | cnpg-system |
| redis-operator | `CHART_VER_REDIS_OPERATOR` | `HELM_REPO_REDIS_OPERATOR` | redis-operator |
| cert-manager | `CHART_VER_CERT_MANAGER` | `HELM_REPO_CERT_MANAGER` | cert-manager |
| vault | `CHART_VER_VAULT` | `HELM_REPO_VAULT` | vault |
| external-secrets | `CHART_VER_EXTERNAL_SECRETS` | `HELM_REPO_EXTERNAL_SECRETS` | external-secrets |
| external-dns | `CHART_VER_EXTERNAL_DNS` | `HELM_REPO_EXTERNAL_DNS` | external-dns |
| kube-prometheus-stack | `CHART_VER_PROMETHEUS_STACK` | `HELM_REPO_PROMETHEUS` | monitoring |
| keycloakx | `CHART_VER_KEYCLOAKX` | `OCI_SRC_KEYCLOAKX` (OCI-native) | keycloak |
| harbor | `CHART_VER_HARBOR` | `HELM_REPO_HARBOR` | harbor |
| argo-cd | `CHART_VER_ARGOCD` | `OCI_SRC_ARGOCD` (OCI-native) | argocd |
| argo-rollouts | `CHART_VER_ARGO_ROLLOUTS` | `OCI_SRC_ARGO_ROLLOUTS` (OCI-native) | argo-rollouts |
| argo-workflows | `CHART_VER_ARGO_WORKFLOWS` | `OCI_SRC_ARGO_WORKFLOWS` (OCI-native) | argo-workflows |
| gitlab | `CHART_VER_GITLAB` | `HELM_REPO_GITLAB` | gitlab |
| gitlab-runner (shared) | `CHART_VER_GITLAB_RUNNER` | `HELM_REPO_GITLAB` | gitlab-runners |
| gitlab-runner (golden-image) | `CHART_VER_GITLAB_RUNNER` | `HELM_REPO_GITLAB` | gitlab-runners |

## Container Images (19 pinned in .env)

These are explicitly pinned in `.env` via `IMAGE_*` variables and used in
raw manifest bundles (Jobs, DaemonSets, CronJobs, StatefulSets).

| Variable | Image | Used By |
|---|---|---|
| `IMAGE_ALPINE_K8S` | docker.io/alpine/k8s:1.32.4 | All init Jobs |
| `IMAGE_CURL` | curlimages/curl:8.12.1 | Health check Jobs |
| `IMAGE_KEYCLOAK` | quay.io/keycloak/keycloak:26.0.8 | Keycloak Deployment (keycloakx Helm chart) |
| `IMAGE_POSTGRESQL_17` | ghcr.io/cloudnative-pg/postgresql:17.6 | CNPG clusters (gitlab, harbor) |
| `IMAGE_POSTGRESQL_16` | ghcr.io/cloudnative-pg/postgresql:16.6 | CNPG clusters (keycloak, grafana) |
| `IMAGE_REDIS` | quay.io/opstree/redis:v7.0.15 | OpsTree Redis instances |
| `IMAGE_REDIS_SENTINEL` | quay.io/opstree/redis-sentinel:v7.0.15 | OpsTree Redis Sentinel |
| `IMAGE_REDIS_EXPORTER` | oliver006/redis_exporter:v1.66.0 | Redis metrics exporter |
| `IMAGE_MINIO` | quay.io/minio/minio:RELEASE.2024-11-07T00-52-20Z | MinIO StatefulSet |
| `IMAGE_MINIO_MC` | quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z | MinIO init Jobs (mc CLI) |
| `IMAGE_LOKI` | docker.io/grafana/loki:3.4.6 | Loki StatefulSet |
| `IMAGE_ALLOY` | docker.io/grafana/alloy:v1.6.1 | Alloy DaemonSet |
| `IMAGE_OAUTH2_PROXY` | quay.io/oauth2-proxy/oauth2-proxy:v7.8.1 | 8 OAuth2-proxy Deployments |
| `IMAGE_NODE_LABELER` | harbor.example.com/library/node-labeler:v0.2.0 | Node labeler DaemonSet |
| `IMAGE_STORAGE_AUTOSCALER` | harbor.example.com/library/storage-autoscaler:v0.2.0 | Storage autoscaler Deployment |
| `IMAGE_CLUSTER_AUTOSCALER` | registry.k8s.io/autoscaling/cluster-autoscaler:v1.34.3 | Cluster autoscaler Deployment |
| `IMAGE_VAULT` | hashicorp/vault:1.21.2 | Vault HA StatefulSet |
| `IMAGE_VALKEY` | valkey/valkey:8-alpine | Harbor Valkey, ArgoCD redis-ha |
| `IMAGE_HAPROXY` | docker.io/library/haproxy:2.9.4-alpine | ArgoCD redis-ha HAProxy |

Additional images are pulled by Helm charts at their pinned chart versions
(Grafana, Prometheus, Alertmanager, ArgoCD components, GitLab components, etc.).

## CRDs

| Source | CRDs Installed |
|---|---|
| prometheus-operator-crds chart | ServiceMonitor, PodMonitor, PrometheusRule, Prometheus, Alertmanager, etc. |
| cert-manager chart (installCRDs: true) | Certificate, Issuer, ClusterIssuer, CertificateRequest, Order, Challenge |
| cloudnative-pg chart | Cluster, Backup, ScheduledBackup, Pooler |
| redis-operator chart | Redis, RedisSentinel, RedisCluster, RedisReplication |
| external-secrets chart | ExternalSecret, SecretStore, ClusterSecretStore, PushSecret |
| external-dns chart | DNSEndpoint |
| Gateway API CRDs (raw bundle) | TCPRoute, TLSRoute, UDPRoute (extends RKE2 built-in Gateway/HTTPRoute) |
| VolumeAutoscaler CRD (raw bundle) | VolumeAutoscaler |
| ArgoCD chart | Application, AppProject, ApplicationSet |
| Argo Rollouts chart | Rollout, AnalysisTemplate, AnalysisRun, Experiment |
| Argo Workflows chart | Workflow, CronWorkflow, WorkflowTemplate, ClusterWorkflowTemplate |
| GitLab chart | Runner (gitlab-runner subchart) |

## Raw Manifest Bundles (42)

Pushed to `oci://${HARBOR_HOST}/fleet/<bundle-name>` at version `BUNDLE_VERSION`.

| Group | Bundle Name | Contents |
|---|---|---|
| 00-operators | operators-node-labeler | DaemonSet, RBAC |
| 00-operators | operators-storage-autoscaler | Deployment, CRD, RBAC |
| 00-operators | operators-cluster-autoscaler | Deployment, RBAC, PDB |
| 00-operators | operators-overprovisioning | Deployment (placeholder pods) |
| 00-operators | operators-gateway-api-crds | TCPRoute, TLSRoute, UDPRoute CRDs |
| 05-pki-secrets | pki-vault-init | Vault init Job (policies, auth, PKI) |
| 05-pki-secrets | pki-vault-unsealer | CronJob (auto-unseal) |
| 05-pki-secrets | pki-vault-init-wait | Sentinel Job |
| 05-pki-secrets | pki-vault-pki-issuer | ClusterIssuer |
| 05-pki-secrets | pki-vault-bootstrap-store | ClusterSecretStore |
| 10-identity | identity-cnpg-keycloak | CNPG Cluster, init Job, SecretStore |
| 10-identity | identity-keycloak-init | Init Job, ExternalSecrets, LDAP CA ConfigMap |
| 10-identity | identity-keycloak-manifests | Gateway, HTTPRoute, Grafana dashboards |
| 10-identity | identity-keycloak-config | Realm/OIDC config Job |
| 11-infra-auth | infra-auth-traefik | OAuth2-proxy, SecretStore, ExternalSecret |
| 11-infra-auth | infra-auth-vault | OAuth2-proxy for Vault UI |
| 11-infra-auth | infra-auth-hubble | OAuth2-proxy, ExternalSecret |
| 15-dns | dns-external-dns-secrets | SecretStore, PushSecret, ExternalSecret |
| 20-monitoring | monitoring-init | Bootstrap Job (OIDC, creds, SecretStores) |
| 20-monitoring | monitoring-cnpg-grafana | CNPG Cluster for Grafana |
| 20-monitoring | monitoring-secrets | ExternalSecrets, vault-root-ca ConfigMap |
| 20-monitoring | monitoring-loki | Loki StatefulSet |
| 20-monitoring | monitoring-alloy | Alloy DaemonSet |
| 20-monitoring | monitoring-ingress-auth | Gateway API, OAuth2-proxies, HPA, VolumeAutoscalers |
| 30-harbor | minio | MinIO StatefulSet, init Job |
| 30-harbor | harbor-init | Bootstrap Job (OIDC, MinIO, creds) |
| 30-harbor | harbor-secrets | ExternalSecrets for harbor-core |
| 30-harbor | harbor-cnpg-harbor | CNPG Cluster, PushSecrets |
| 30-harbor | harbor-valkey | Valkey HA (OpsTree), PushSecret |
| 30-harbor | harbor-manifests | Gateway API, OIDC config, monitoring |
| 40-gitops | gitops-argocd-init | Bootstrap Job (OIDC, creds, SecretStore) |
| 40-gitops | gitops-argocd-credentials | ExternalSecret for argocd-secret |
| 40-gitops | gitops-argocd-manifests | Gateway API, PDBs, dashboards, alerts |
| 40-gitops | gitops-argocd-gitlab-setup | GitLab PAT + ArgoCD repo setup Job |
| 40-gitops | gitops-rollouts-init | Bootstrap Job |
| 40-gitops | gitops-argo-rollouts-manifests | OAuth2-proxy, Gateway API, dashboards |
| 40-gitops | gitops-workflows-init | Bootstrap Job |
| 40-gitops | gitops-argo-workflows-manifests | OAuth2-proxy, Gateway API, CronWorkflows |
| 40-gitops | gitops-analysis-templates | AnalysisTemplate CRs |
| 50-gitlab | gitlab-init | Bootstrap Job (OIDC, MinIO, creds) |
| 50-gitlab | gitlab-cnpg-gitlab | CNPG Cluster, PushSecrets |
| 50-gitlab | gitlab-redis | OpsTree Redis Sentinel HA |
| 50-gitlab | gitlab-credentials | ExternalSecrets for gitlab-core |
| 50-gitlab | gitlab-ready | Sentinel Job |
| 50-gitlab | gitlab-manifests | Gateway API, ExternalSecrets, monitoring, JWT auth |
| 50-gitlab | gitlab-runners | SecretStore, PushSecrets, runner setup Job |
