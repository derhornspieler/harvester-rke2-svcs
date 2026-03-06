# GitLab

GitLab EE deployment on RKE2 with Praefect/Gitaly HA, CloudNativePG PostgreSQL, OpsTree Redis Sentinel, and Kubernetes-executor runners.

## Architecture

```
                    Internet / LAN
                         |
              +----------+----------+
              | Traefik (DaemonSet) |
              +---+------------+----+
                  |            |
         HTTPS :8443      TCP :2222
                  |            |
           +------+------+    |
           |   Gateway   |    |
           | (gitlab ns) |    |
           +------+------+    |
                  |            |
     +--------+---+---+       |
     |        |       |       |
  gitlab.*  kas.*  minio.*    |
     |        |       |       |
     v        v       v       v
 +-------+ +-----+ +-----+ +-------+
 |  Web  | | KAS | |MinIO| | Shell |
 |service| |     | |     | | (SSH) |
 +---+---+ +-----+ +-----+ +-------+
     |
     +--------+--------+--------+
     |        |        |        |
     v        v        v        v
 +-------+ +------+ +------+ +--------+
 |Sidekiq| |Praef.| |Gitaly| |Exporter|
 |       | |(HA)  | |(x3)  | |        |
 +---+---+ +--+---+ +------+ +--------+
     |        |
     v        v
 +-------+ +-------+   +----------+
 |  CNPG | | Redis |   |  Runners |
 | PG 17 | | Sent. |   | (3 pools)|
 | (3x)  | | (3+3) |   +----------+
 +-------+ +-------+
```

### Component summary

| Component | Technology | Replicas | Node pool |
|-----------|-----------|----------|-----------|
| Webservice (Rails + Workhorse) | GitLab EE | 2-10 (HPA) | compute |
| Sidekiq (background jobs) | GitLab EE | 2-10 (HPA) | compute |
| Gitaly (Git storage) | Praefect-managed | 3 | compute |
| Praefect (Gitaly HA proxy) | GitLab EE | 2 | compute |
| GitLab Shell (SSH) | GitLab EE | 2-6 (HPA) | general |
| KAS (Kubernetes Agent) | GitLab EE | 2-6 (HPA) | general |
| GitLab Exporter | GitLab EE | 1 | general |
| Toolbox | GitLab EE | 1 | general |
| MinIO (object storage) | MinIO | 1 | general |
| PostgreSQL | CloudNativePG 17 | 3 (1 primary + 2 replicas) | database |
| Redis | OpsTree Replication | 3 (1 master + 2 replicas) | database |
| Redis Sentinel | OpsTree Sentinel | 3 | database |
| Redis Exporter | oliver006/redis_exporter | 1 per Redis pod | database |

### Networking

- **HTTPS**: Gateway API with Traefik GatewayClass, cert-manager vault-issuer for TLS
- **SSH**: TCP Gateway listener on port 2222, routed via TCPRoute to gitlab-shell service on port 22
- **Hostnames**: `gitlab.example.com`, `kas.example.com`, `minio.example.com`

### SSH access via TCP Gateway

Git over SSH is exposed on port 2222 through the Traefik TCP Gateway listener. Users connect with:

```bash
git clone ssh://git@gitlab.example.com:2222/group/project.git
```

Or configure `~/.ssh/config`:

```
Host gitlab.example.com
  Port 2222
  User git
```

### Data backends

- **PostgreSQL**: CloudNativePG Cluster CR in `database` namespace. 3 instances with streaming replication, automatic failover, and daily Barman backups to MinIO. Services: `gitlab-postgresql-rw` (primary), `gitlab-postgresql-ro` (replicas).
- **Redis**: OpsTree RedisReplication (3 pods) + RedisSentinel (3 pods) in `gitlab` namespace. GitLab discovers the primary via Sentinel (`mymaster` group). Password synced from Vault via ExternalSecret.
- **Object storage**: Bundled MinIO (single instance). Replace with external S3-compatible storage for production scale.

## Deployment

Deploy with the `deploy-gitlab.sh` script (9 phases, approximately 50-70 minutes on first install):

```bash
# Full deployment
./scripts/deploy-gitlab.sh

# Run a single phase
./scripts/deploy-gitlab.sh --phase 4

# Resume from a specific phase
./scripts/deploy-gitlab.sh --from 7

# Validate all components without changes
./scripts/deploy-gitlab.sh --validate
```

### Prerequisites

1. Bundles 1-4 deployed (PKI/Vault, cert-manager, ESO, monitoring stack)
2. CloudNativePG operator installed in `cnpg-system`
3. OpsTree Redis Operator installed in `redis-operator-system`
4. `.env` populated with `GITLAB_ROOT_PASSWORD` and `GITLAB_REDIS_PASSWORD`

### Phase overview

| Phase | Name | Duration | Description |
|-------|------|----------|-------------|
| 1 | Namespaces and RBAC | ~10s | Create `gitlab` and `gitlab-runners` namespaces, ServiceAccount, RBAC |
| 2 | Vault secrets | ~30s | Seed Vault KV with root password, Redis password, Gitaly/Praefect tokens, OIDC provider config |
| 3 | External Secrets | ~1 min | Deploy ExternalSecret CRs; ESO syncs Vault secrets into K8s Secrets |
| 4 | PostgreSQL (CNPG) | ~5 min | Deploy CNPG Cluster (3 instances) + ScheduledBackup CR |
| 5 | Redis (OpsTree) | ~3 min | Deploy RedisReplication (3 pods) + RedisSentinel (3 pods) |
| 6 | Gateway API | ~30s | Deploy Gateway (HTTPS + TCP listeners) and TCPRoute for SSH |
| 7 | GitLab Helm install | ~30-45 min | Install GitLab chart; first run includes DB migrations |
| 8 | GitLab Runners | ~3 min | Install 3 runner Helm releases (shared, security, group) |
| 9 | Monitoring | ~1 min | Deploy ServiceMonitors, PrometheusRules, Grafana dashboards, VolumeAutoscalers |

## Post-deploy

### Upload Ultimate license

1. Log in as `root` with the password from Vault (`services/gitlab/initial-root-password`)
2. Navigate to **Admin Area > License**
3. Upload the `.gitlab-license` file

### Configure OIDC client in Keycloak

1. In the Keycloak `platform` realm, create an OpenID Connect client:
   - **Client ID**: `gitlab`
   - **Root URL**: `https://gitlab.example.com`
   - **Valid Redirect URIs**: `https://gitlab.example.com/users/auth/openid_connect/callback`
   - **Web Origins**: `https://gitlab.example.com`
2. Store the client secret in Vault at `services/gitlab/oidc-secret` with key `provider` containing the OmniAuth JSON config
3. ESO syncs the secret automatically (refresh interval: 15 min)

### Verify runner registration

```bash
# Check runner pods are running
kubectl get pods -n gitlab-runners

# Verify runners registered in GitLab
# Admin Area > CI/CD > Runners should show 3 runners:
#   - shared-k8s-runner     (tags: shared, kubernetes, compute)
#   - security-k8s-runner   (tags: security, trivy, semgrep, gitleaks)
#   - platform-services-k8s-runner (tags: group, kubernetes, platform-services)
```

## Runners

Three runner pools are deployed, each as a separate Helm release in the `gitlab-runners` namespace. All use the Kubernetes executor and spawn job pods on `compute` nodes.

| Runner | Tags | Runs untagged | Purpose |
|--------|------|---------------|---------|
| shared-k8s-runner | `shared`, `kubernetes`, `compute` | Yes | General-purpose CI/CD |
| security-k8s-runner | `security`, `trivy`, `semgrep`, `gitleaks` | No | Dedicated security scanning |
| platform-services-k8s-runner | `group`, `kubernetes`, `platform-services` | Yes | Platform services group |

### Runner configuration

- **Namespace**: Job pods run in `gitlab-runners`
- **Service account**: `gitlab-runner-sa` with scoped RBAC (pods, logs, exec, attach, secrets, configmaps, PVCs)
- **Root CA trust**: Vault root CA mounted at `/etc/ssl/certs/vault-root-ca.pem` in both manager and job pods
- **Harbor push**: `harbor-ci-push` secret (synced from Vault via ESO) for pushing images
- **Metrics**: Prometheus metrics exposed on port 9252

## CI Templates

Reusable CI/CD templates are stored in `ci-templates/` and published to a `platform_services/gitlab-ci-templates` repo in GitLab. Projects include templates via:

```yaml
include:
  - project: 'platform_services/gitlab-ci-templates'
    file:
      - '/stages.yml'
      - '/patterns/microservice.yml'
```

### Pipeline patterns

| Pattern | File | Stages |
|---------|------|--------|
| Microservice | `patterns/microservice.yml` | gitleaks, hadolint, kaniko build, trivy scan, SBOM, ArgoCD deploy, promote |
| Platform service | `patterns/platform-service.yml` | ESO provision, gitleaks, hadolint, kaniko build, trivy scan, SBOM, blue-green deploy, promote |
| Library | `patterns/library.yml` | gitleaks, yamllint, semgrep SAST, trivy fs scan |
| Infrastructure | `patterns/infrastructure.yml` | gitleaks, yamllint, kubectl dry-run validate |

### Job templates

| Job | Image | Stage |
|-----|-------|-------|
| `.build:kaniko` | `gcr.io/kaniko-project/executor:v1.23.2-debug` | build |
| `.scan:gitleaks` | `zricethezav/gitleaks:latest` | pre-check |
| `.scan:semgrep` | `semgrep/semgrep:latest` | scan |
| `.scan:trivy-fs` | `aquasec/trivy:latest` | scan |
| `.scan:trivy-image` | `aquasec/trivy:latest` | scan |
| `.scan:sbom` | `anchore/syft:latest` | scan |
| `.scan:license` | `aquasec/trivy:latest` | scan |
| `.lint:hadolint` | `hadolint/hadolint:latest-alpine` | lint |
| `.lint:yamllint` | `cytopia/yamllint:latest` | lint |
| `.lint:shellcheck` | `koalaman/shellcheck-alpine:stable` | lint |
| `.deploy:argocd-sync` | `argoproj/argocd:v2.14.0` | deploy-staging |
| `.deploy:kustomize-update` | `bitnami/git:latest` | deploy-staging |
| `.deploy:blue-green` | `bitnami/git:latest` | deploy-staging |
| `.promote:tag-image` | `gcr.io/go-containerregistry/crane:debug` | deploy-production |
| `.provision:eso` | `hashicorp/vault:1.18` | provision |
| `.test:go` | `golang:1.23-alpine` | test |
| `.test:node` | `node:22-alpine` | test |
| `.test:python` | `python:3.12-slim` | test |

## Monitoring

### ServiceMonitors

| Monitor | Namespace | Target |
|---------|-----------|--------|
| `gitlab-exporter` | monitoring | GitLab exporter metrics (Puma, Sidekiq, Gitaly, etc.) |
| `service-monitor-redis` | monitoring | OpsTree Redis replication metrics |
| `runners-service-monitor` | monitoring | GitLab Runner metrics (port 9252) |
| CNPG PodMonitor | database | PostgreSQL metrics (auto-created by CNPG operator) |

### Alerts (PrometheusRules)

**GitLab alerts** (`gitlab-alerts`):
- `GitLabDown` -- exporter unreachable for 5 min (critical)
- `GitLabSidekiqHighFailureRate` -- job failure rate above 5% for 10 min (warning)
- `GitLabSidekiqQueueBacklog` -- queue size above 1000 for 15 min (warning)
- `GitLabGitalyHighLatency` -- p99 unary RPC latency above 5s for 10 min (warning)
- `GitLabPumaThreadExhaustion` -- thread utilization above 90% for 10 min (warning)
- `GitLabHighServerErrorRate` -- HTTP 5xx rate above 5% for 10 min (critical)

**Runner alerts** (`gitlab-runner-alerts`):
- `GitLabRunnerDown` -- all runner pods unready for 10 min (critical)
- `GitLabRunnerHighFailureRate` -- job failure rate above 30% for 30 min (warning)

### Grafana dashboards

- **GitLab Overview**: Puma threads, Sidekiq jobs, Gitaly latency, HTTP error rates
- **GitLab Runners**: Job throughput, failure rate, queue time, active jobs per runner

### Volume autoscalers

| Autoscaler | Namespace | Target | Threshold | Max |
|------------|-----------|--------|-----------|-----|
| `gitlab-pg` | database | CNPG PVCs | 80% | 200Gi |
| `gitlab-redis` | gitlab | Redis PVCs | 80% | 50Gi |

## External Secrets (Vault)

All secrets are stored in Vault KV v2 and synced into Kubernetes via ESO ExternalSecrets.

| ExternalSecret | K8s Secret | Vault path | Namespace |
|----------------|-----------|------------|-----------|
| `gitlab-gitlab-initial-root-password` | `gitlab-gitlab-initial-root-password` | `services/gitlab/initial-root-password` | gitlab |
| `gitlab-redis-credentials` | `gitlab-redis-credentials` | `services/gitlab/redis` | gitlab |
| `gitlab-gitaly-secret` | `gitlab-gitaly-secret` | `services/gitlab/gitaly-secret` | gitlab |
| `gitlab-praefect-dbsecret` | `gitlab-praefect-dbsecret` | `services/gitlab/praefect-dbsecret` | gitlab |
| `gitlab-praefect-secret` | `gitlab-praefect-secret` | `services/gitlab/praefect-secret` | gitlab |
| `gitlab-oidc-secret` | `gitlab-oidc-secret` | `services/gitlab/oidc-secret` | gitlab |
| `harbor-ci-push` | `harbor-ci-push` | `ci/harbor-push` | gitlab-runners |

## Day-2 Operations

| SOP | Description |
|-----|-------------|
| [PgBouncer Connection Pooling and Read-Replica Load Balancing](docs/pgbouncer-read-replica-sop.md) | CNPG Pooler CRs, transaction-mode pooling, read/write split, monitoring, and troubleshooting |

## File structure

```
services/gitlab/
  MANIFEST.yaml                        # Component inventory
  README.md                            # This file
  kustomization.yaml                   # Main Kustomize entrypoint
  namespace.yaml                       # gitlab namespace
  values-rke2-prod.yaml                # Helm values for gitlab/gitlab chart
  gateway.yaml                         # Gateway API (HTTPS + TCP listeners)
  tcproute-ssh.yaml                    # TCPRoute for SSH on port 2222
  cloudnativepg-cluster.yaml           # CNPG PostgreSQL Cluster CR
  cloudnativepg-scheduled-backup.yaml  # Daily backup ScheduledBackup CR
  volume-autoscalers.yaml              # PVC autoscaler CRs
  redis/
    replication.yaml                   # OpsTree RedisReplication CR (3 pods)
    sentinel.yaml                      # OpsTree RedisSentinel CR (3 pods)
    external-secret.yaml               # Redis password from Vault
  gitaly/
    external-secret.yaml               # Gitaly auth token from Vault
  praefect/
    external-secret-dbsecret.yaml      # Praefect DB password from Vault
    external-secret-token.yaml         # Praefect auth token from Vault
  oidc/
    external-secret.yaml               # OIDC provider config from Vault
  root/
    external-secret.yaml               # Root password from Vault
  runners/
    kustomization.yaml                 # Runner Kustomize entrypoint
    namespace.yaml                     # gitlab-runners namespace
    rbac.yaml                          # ServiceAccount + Role + RoleBinding
    shared-runner-values.yaml          # Helm values: shared runner
    security-runner-values.yaml        # Helm values: security scanner runner
    group-runner-values.yaml           # Helm values: platform-services group runner
    external-secret-harbor-push.yaml   # Harbor CI push credentials from Vault
  monitoring/
    kustomization.yaml                 # Monitoring Kustomize entrypoint
    service-monitor.yaml               # ServiceMonitor for GitLab exporter
    service-monitor-redis.yaml         # ServiceMonitor for Redis
    runners-service-monitor.yaml       # ServiceMonitor for runners
    gitlab-alerts.yaml                 # PrometheusRule: GitLab alerts
    gitlab-runner-alerts.yaml          # PrometheusRule: runner alerts
    configmap-dashboard-gitlab.yaml    # Grafana dashboard: GitLab overview
    configmap-dashboard-gitlab-runners.yaml  # Grafana dashboard: runners
  ci-templates/
    base.yml                           # Shared variables and Vault JWT auth
    stages.yml                         # Standard pipeline stages
    jobs/
      build.yml                        # Kaniko container build
      deploy.yml                       # ArgoCD sync + kustomize update
      eso-provision.yml                # Self-service ESO provisioning
      lint.yml                         # hadolint, yamllint, shellcheck
      promote.yml                      # Production image promotion (crane)
      rollout.yml                      # Blue/Green deployment via ArgoCD Rollouts
      scan.yml                         # gitleaks, semgrep, trivy, syft SBOM
      test.yml                         # Go, Node.js, Python test templates
    patterns/
      infrastructure.yml               # Lint + validate pattern
      library.yml                      # Lint + test + scan pattern
      microservice.yml                 # Full build-scan-deploy pattern
      platform-service.yml             # ESO + build-scan-blue/green pattern
```
