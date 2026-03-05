# GitLab Bundle Design

**Date:** 2026-03-05
**Status:** Approved
**Bundle:** 6 of 6 (Final)

## Overview

Deploy self-hosted GitLab EE (Ultimate licensed) with Praefect/Gitaly HA, Kubernetes-executor runners, and shared CI pipeline templates. All sub-components consolidated under `services/gitlab/`.

## Services

| Service | Mode | Purpose |
|---------|------|---------|
| GitLab EE | Helm chart (gitlab/gitlab) | Git server, CI/CD, code review |
| Praefect + Gitaly | Helm-managed (3 Gitaly replicas) | Repository HA with consensus routing |
| CNPG PostgreSQL 17 | Operator-managed (3-instance, 50Gi) | GitLab + Praefect databases |
| Redis Sentinel | OpsTree Operator (3+3) | Session/cache/job queue |
| GitLab Runners | Helm chart (3 instances) | K8s executor — shared, security, group |
| CI Templates | Shared pipeline definitions | Kaniko builds, Trivy scanning, ArgoCD deploy |

## Architecture

```
Users → Traefik Gateway
  ├── HTTPS (8443) → GitLab Webservice (Puma)
  ├── HTTPS (8443) → GitLab KAS (Kubernetes Agent)
  └── TCP (2222) → GitLab Shell (SSH git operations)

GitLab → Praefect (2 replicas) → Gitaly (3 replicas, repository storage)
GitLab → CNPG PostgreSQL (3-instance, database namespace)
GitLab → Redis Sentinel (3+3, gitlab namespace)
GitLab → Keycloak (OIDC via omniauth)
GitLab → Harbor (container registry, disabled internal registry)

GitLab Runners (gitlab-runners namespace):
  ├── shared-runner (kubernetes executor, compute nodes)
  ├── security-runner (trivy, semgrep, gitleaks tags)
  └── group-runner (platform_services group)
  Each job → creates pod → runs → cleans up
```

## Directory Structure

```
services/gitlab/
├── kustomization.yaml
├── namespace.yaml
├── gateway.yaml                        # HTTPS + TCP SSH listeners
├── tcproute-ssh.yaml                   # TCP passthrough port 2222 → shell:22
├── values-rke2-prod.yaml               # GitLab Helm values (EE, external PG/Redis/OIDC)
├── cloudnativepg-cluster.yaml          # 3-instance PostgreSQL 17, 50Gi
├── cloudnativepg-scheduled-backup.yaml # Daily Barman backup to MinIO
├── gitaly/
│   └── external-secret.yaml            # Gitaly auth token
├── praefect/
│   ├── external-secret-dbsecret.yaml   # Praefect DB credentials
│   └── external-secret-token.yaml      # Praefect auth token
├── redis/
│   ├── replication.yaml                # 3-replica Redis
│   ├── sentinel.yaml                   # 3-instance Sentinel
│   └── external-secret.yaml            # Redis credentials
├── oidc/
│   └── external-secret.yaml            # Keycloak OIDC provider config
├── root/
│   └── external-secret.yaml            # GitLab root initial password
├── runners/
│   ├── namespace.yaml                  # gitlab-runners namespace
│   ├── rbac.yaml                       # SA + Role + RoleBinding for job pods
│   ├── external-secret-harbor-push.yaml # Harbor CI push credentials
│   ├── shared-runner-values.yaml       # Instance-wide shared runner
│   ├── security-runner-values.yaml     # Security scanning runner
│   └── group-runner-values.yaml        # platform_services group runner
├── ci-templates/
│   ├── base.yml                        # Global variables, Vault JWT auth
│   ├── stages.yml                      # Standard pipeline stages
│   ├── jobs/                           # Build, scan, test, deploy, rollout
│   └── patterns/                       # Microservice, platform-service, library
├── monitoring/
│   ├── kustomization.yaml
│   ├── service-monitor.yaml
│   ├── service-monitor-redis.yaml
│   ├── gitlab-alerts.yaml (7 rules)
│   ├── configmap-dashboard-gitlab.yaml
│   └── configmap-dashboard-gitlab-runners.yaml
├── volume-autoscalers.yaml             # CNPG, Redis, Gitaly PVCs
├── MANIFEST.yaml
└── README.md
```

## Deploy Script (scripts/deploy-gitlab.sh) — 9 Phases

| Phase | Component | What Happens |
|-------|-----------|--------------|
| 1 | Namespaces | Create gitlab, gitlab-runners, ensure database namespace |
| 2 | ESO | SecretStores + ExternalSecrets (gitaly, praefect, redis, oidc, root, harbor-push) |
| 3 | PostgreSQL | CNPG cluster (3-instance, extensions: pg_trgm, btree_gist), wait for primary, create praefect DB, scheduled backup |
| 4 | Redis | Sentinel HA (3+3), wait for all pods |
| 5 | Gateway | Gateway (HTTPS + TCP listeners), TCPRoute SSH, wait for TLS cert |
| 6 | GitLab Helm | Substitute values, helm install (EE, external PG/Redis/OIDC), wait for migrations + deployments |
| 7 | Runners | 3 Helm installs (shared, security, group), RBAC, Harbor push creds |
| 8 | VolumeAutoscalers | Apply autoscaler CRs for CNPG, Redis, Gitaly PVCs |
| 9 | Monitoring + Verify | Apply monitoring, verify HTTPS + SSH connectivity |

## Post-Deploy Steps (Manual)

1. **Upload Ultimate license** via GitLab Admin UI or API
2. **Create OIDC client** in Keycloak (via setup-keycloak.sh extension)
3. **Configure proxy cache** in Harbor for GitLab container registry
4. **Push CI templates** to GitLab as a shared project

## Licensing

- GitLab EE edition set in Helm values (`global.edition: ee`)
- Ultimate license applied post-deploy via Admin UI or API (not in manifests)
- Registration key file from source repo applied manually

## Resource Conventions

- **Requests only, no limits**
- **HPA:** Webservice (2-10), Sidekiq (2-10), Shell (2-6), KAS (2-6) — Helm-managed
- **VolumeAutoscaler:** CNPG PVCs (50Gi→200Gi), Redis PVCs (10Gi→50Gi), Gitaly PVCs
- **Anti-affinity:** All replicated components
- **Node selectors:**
  - `database`: CNPG, Redis, Gitaly
  - `compute`: Webservice, Sidekiq, Runner job pods
  - `general`: Shell, KAS, Exporter, Runner manager pods

## Secrets (Vault/ESO)

| Secret | Vault Path | Purpose |
|--------|------------|---------|
| gitlab-gitaly-secret | services/gitlab/gitaly-secret | Gitaly auth token |
| gitlab-praefect-secret | services/gitlab/praefect-secret | Praefect token |
| gitlab-praefect-dbsecret | services/gitlab/praefect-dbsecret | Praefect DB creds |
| gitlab-redis-credentials | services/gitlab/redis | Redis password |
| gitlab-oidc-secret | services/gitlab/oidc-secret | Keycloak OIDC config |
| gitlab-initial-root-password | services/gitlab/initial-root-password | Root user password |
| harbor-ci-push | ci/harbor-push | Harbor push creds for runners |

## Dependencies

- Bundle 1 (PKI & Secrets): TLS, Vault, ESO
- Bundle 2 (Identity): Keycloak OIDC for GitLab SSO, CNPG operator, shared MinIO
- Bundle 3 (Monitoring): Prometheus, Grafana dashboards, ServiceMonitors
- Bundle 4 (Harbor): Harbor for runner image pushes
- Bundle 5 (GitOps): ArgoCD for deployment patterns in CI templates
- Redis Operator (OpsTree): For Redis Sentinel HA
