# Cluster vs Code Audit — rke2-prod

**Date**: 2026-03-06
**Purpose**: Deep comparison of live rke2-prod cluster state vs harvester-rke2-svcs codebase to ensure full reproducibility via scripts in correct sequential order.
**Status**: COMPLETE
**Environment**: AIRGAPPED — cluster has NO internet access. ALL container images, Helm charts, RPM repos, and RKE2 binaries must be sourced via Harbor proxy-cache (`harbor.example.com`). Any direct pull from quay.io, ghcr.io, docker.io, registry.k8s.io, or GitHub raw URLs will **FAIL** on a fresh deploy.

## Cluster Topology

| Pool | Nodes | K8s Version |
|------|-------|-------------|
| controlplane | 3 | v1.34.4+rke2r1 |
| database | 4 | v1.34.4+rke2r1 |
| general | 4 | v1.34.4+rke2r1 |
| compute | 2 | v1.34.4+rke2r1 |
| **Total** | **13** | |

## Audit Progress Tracker

| Phase | Bundle | Agent(s) | Status | Findings |
|-------|--------|----------|--------|----------|
| 0 | Pre-bundle (system namespaces, operators, Cilium/Hubble, Traefik) | k8s-infra-engineer | DONE | 2 CRITICAL, 4 MODERATE, 4 LOW |
| 1 | Bundle 1: PKI & Secrets (Vault, cert-manager, ESO) | platform-developer + security-sentinel | DONE | 1 MEDIUM, 3 LOW, 3 INFO |
| 2 | Bundle 2: Identity (Keycloak, CNPG, MinIO, OAuth2-proxy) | all 5 agents | DONE | 3 CRITICAL, 6 HIGH, 4 MEDIUM |
| 3 | Bundle 3: Monitoring (Prometheus, Grafana, Loki, Alloy) | all 5 agents | DONE | 2 HIGH, 1 MEDIUM, 2 LOW |
| 4 | Bundle 4: Harbor (Harbor, CNPG, Valkey, MinIO) | platform-developer + security-sentinel + k8s-infra | DONE (deep-dive complete) | 4 CRITICAL, 6 HIGH, 6 MEDIUM |
| 5 | Bundle 5: GitOps (ArgoCD, Rollouts, Workflows) | platform-engineer + security-sentinel + k8s-infra | DONE | 5 HIGH, 8 MEDIUM, 2 LOW |
| 6 | Bundle 6: Git & CI (GitLab, Redis, CNPG, Runners) | platform-developer + k8s-infra | DONE | 4 HIGH, 2 MEDIUM, 1 LOW |
| 7 | Cross-cutting: ServiceMonitors, PrometheusRules, Dashboards | platform-engineer | DONE | 30/30 SMs match, 22/22 PRs match, 2 code-only not applied |
| 8 | Cross-cutting: VolumeAutoscalers, HPAs, PDBs | k8s-infra-engineer | DONE | Multiple VAs/HPAs defined but not applied; missing PDBs for ArgoCD + Harbor |
| 9 | Cross-cutting: Secrets/ESO, RBAC, TLS/Certs | security-sentinel | DONE | Inline secrets in Harbor, empty defaults in subst.sh |
| 10 | Documentation sync | tech-doc-keeper | DONE | 2 CRITICAL, 3 HIGH, 1 MEDIUM |

## Live Cluster Inventory

### Namespaces (28 total)

**System**: default, kube-system, kube-public, kube-node-lease, cattle-system, cattle-impersonation-system, cattle-local-user-passwords, cattle-fleet-system, local, cilium-secrets
**Pre-bundle operators**: cnpg-system, redis-operator, storage-autoscaler, node-labeler, cluster-autoscaler
**Bundle 1**: vault, cert-manager, external-secrets
**Bundle 2**: keycloak, minio, database
**Bundle 3**: monitoring
**Bundle 4**: harbor
**Bundle 5**: argocd, argo-rollouts, argo-workflows
**Bundle 6**: gitlab, gitlab-runners

### Helm Releases (deployed)

| Namespace | Release | Version |
|-----------|---------|---------|
| argocd | argocd | 2 |
| argo-rollouts | argo-rollouts | 1 |
| argo-workflows | argo-workflows | 1 |
| cert-manager | cert-manager | 1 |
| external-secrets | external-secrets | 1 |
| gitlab | gitlab | 14 |
| gitlab-runners | gitlab-runner-group | 1 |
| gitlab-runners | gitlab-runner-security | 1 |
| gitlab-runners | gitlab-runner-shared | 2 |
| harbor | harbor | 11 |
| monitoring | kube-prometheus-stack | 10 |
| vault | vault | 1 |

### CNPG Clusters (all in `database` namespace)

| Cluster | Instances | Poolers | Scheduled Backup |
|---------|-----------|---------|------------------|
| keycloak-pg | 3 | none | keycloak-pg-daily |
| harbor-pg | 3 | none | harbor-pg-daily |
| gitlab-postgresql | 3 | rw, ro | gitlab-postgresql-daily |
| grafana-pg | 3 | none | grafana-pg-daily |

### Gateways (13)

argo-rollouts, argo-workflows, argocd, gitlab, harbor, keycloak, hubble, traefik-dashboard, traefik-gateway, alertmanager, monitoring (grafana), prometheus, vault

### HTTPRoutes (13)

argo-rollouts, argo-workflows, argocd, gitlab-gitlab, gitlab-kas, harbor, keycloak, hubble, traefik-dashboard, alertmanager, grafana, prometheus, vault

### OAuth2-proxy instances (6)

monitoring: alertmanager, prometheus
kube-system: hubble, traefik
argo-rollouts: rollouts
argo-workflows: workflows

### HelmChartConfigs (3)

kube-system: harvester-cloud-provider, rke2-cilium, rke2-traefik

### VolumeAutoscalers (5)

database: gitlab-pg, grafana-pg
gitlab: gitlab-redis
monitoring: loki, prometheus

---

## Findings

### Phase 0: Pre-bundle / System Components

**Status**: DONE

#### Cilium HelmChartConfig — CRITICAL DRIFT

| Setting | Code | Live | Match? |
|---------|------|------|--------|
| hubble.metrics.enabled (6 types) | dns, drop, tcp, flow, icmp, httpV2 | MISSING from live valuesContent | NO |
| hubble.relay.replicas | 2 | 1 | NO |
| hubble.relay.nodeSelector | workload-type: general | kubernetes.io/os: linux only | NO |
| hubble.relay.affinity | podAntiAffinity preferred | podAffinity (colocate with cilium) | NO |
| hubble.relay.resources | cpu:50m, mem:64Mi | empty {} | NO |
| hubble.ui.nodeSelector | workload-type: general | kubernetes.io/os: linux only | NO |
| hubble.ui.resources | cpu:25m, mem:32Mi | empty {} | NO |
| hubble.export.static (flowLogs) | Full fieldMask config | MISSING | NO |

**Root cause**: RKE2 managed-chart controller (`objectset.rio.cattle.io`) merges/strips user HelmChartConfig values. `last-applied-configuration` retains full code, but actual rendered values are minimal.

#### Traefik HelmChartConfig — IN SYNC

All values match. Dashboard, Gateway API, SSH port, LB IP, volumes — all correct.

#### OAuth2-proxy-traefik — DRIFT

Live deployment missing 3 args vs code: `--cookie-expire=4h`, `--cookie-refresh=2h`, `--metrics-address=0.0.0.0:44180`. Code was updated after deployment but not re-applied.

#### Traefik Dashboard — NO DEPLOY SCRIPT

`services/traefik-dashboard/` has 7 YAML files but no `deploy-traefik-dashboard.sh` and no `kustomization.yaml`. Resources must be applied manually.

#### Pre-bundle Operators — NOT IN THIS REPO

| Operator | Live | Code in Repo? | Managed By |
|----------|------|---------------|------------|
| cnpg-system | Running, HPA 2-4, PDB min:1 | Installed by deploy-keycloak.sh Phase 1 | Helm (this repo, partial) |
| redis-operator | Running, HPA 2-4, PDB min:1 | **NONE** | Unknown |
| storage-autoscaler | Running, HPA 3-6 | **NONE** | Terraform (external) |
| node-labeler | Running, HPA 3-6 | **NONE** | Terraform (external) |
| cluster-autoscaler | Running, PDB min:1 | **NONE** | Terraform (external) |

**CNPG nodeSelector drift**: Code says `workload-type=general`, live has `workload-type=database`.
**CNPG HPA + PDB**: Live has both but no YAML in repo — cannot reproduce.

### Phase 1: Bundle 1 — PKI & Secrets

**Status**: DONE

#### Helm Releases — ALL MATCH

- Vault 0.32.0: 3 replicas, 10Gi PVCs, database nodeSelector, anti-affinity, requests-only — all correct
- cert-manager v1.19.4: CRDs, Gateway API enabled — correct
- ESO 2.0.1: CRDs, nodeSelector general, requests 100m/128Mi — correct

#### Gaps Found

| Component | Issue | Severity |
|-----------|-------|----------|
| Vault PVCs | No VolumeAutoscaler CRs for `data-vault-{0,1,2}` — convention requires them | MEDIUM |
| cert-manager cainjector/webhook | Running on compute nodes, not general — `--set nodeSelector` only applies to controller, not cainjector/webhook | LOW |
| Namespace labels | `vault` and `cert-manager` namespace YAMLs define `app:` labels but Helm `--create-namespace` skips them | LOW |
| Images not via Harbor | Vault=Docker Hub, cert-manager=quay.io, ESO=ghcr.io — not routed through Harbor pull-through cache | INFO |
| SecretStores | All 11 namespace-scoped `vault-backend` SecretStores are inline heredocs in deploy scripts — no standalone YAML manifests | INFO |
| vault-root-ca ConfigMaps | All 9 instances are procedural (kubectl create in scripts) — no declarative YAML | INFO |

#### Verified Accurate

- All 5 Vault services, Gateway/HTTPRoute, PDB, TLS cert
- ClusterIssuer `vault-issuer` with correct Vault PKI path
- All RBAC (SA, Role, RoleBinding for cert-manager)
- All 9 monitoring resources (3 ServiceMonitors, 3 PrometheusRules, 3 Grafana dashboards)
- PKI tooling: Root CA, intermediate CA, signing role, K8s auth — all reproducible

### Phase 2: Bundle 2 — Identity

**Status**: DONE

#### CRITICAL Findings

| Component | Issue |
|-----------|-------|
| CNPG operator deployment name | `deploy-keycloak.sh:123` calls `wait_for_deployment cnpg-system cnpg-cloudnative-pg` but live name is `cnpg-controller-manager`. **Fresh deploy would FAIL.** |
| CNPG operator version | Code pins chart v0.23.0 (operator v1.25.0), live is v1.28.1. Re-deploy would **downgrade by 3 minor versions.** |
| CNPG operator nodeSelector | Code: `general`, live: `database`. Re-deploy would reschedule to wrong pool. |

#### HIGH Findings

| Component | Issue |
|-----------|-------|
| Harbor pull-through not used | CNPG operator (ghcr.io), CNPG PostgreSQL (live uses ghcr.io, code uses Harbor proxy but live diverged), Keycloak (quay.io), MinIO (quay.io), OAuth2-proxy (quay.io) |
| OAuth2-proxy security context inconsistency | Hubble has full hardening (readOnlyRootFilesystem, drop ALL). Prometheus + Alertmanager proxies have NO container securityContext. |
| MinIO mc job uses `:latest` tag | `job-create-buckets.yaml` uses `quay.io/minio/mc:latest` — violates pinning standard |
| Keycloak monitoring not applied | ServiceMonitor, PrometheusRule, dashboard defined in `services/keycloak/monitoring/` but NOT on cluster |

#### MEDIUM Findings

| Component | Issue |
|-----------|-------|
| VolumeAutoscaler `keycloak-pg` | Defined in code but NOT applied to cluster |
| kube-system SecretStore | Not created by any Bundle 2 script (created by deploy-hubble.sh) — dependency undocumented |
| MANIFEST.yaml | Shows 7 phases with different grouping than actual 8-phase deploy script |
| MinIO manifests path | Lives under `services/harbor/minio/` but MinIO is shared service — misleading |

#### Verified Accurate

- Keycloak deployment: image, env vars, security context, nodeSelector, topology spread, anti-affinity, resources, probes, HPA (2-5, 70% CPU)
- All services (keycloak, keycloak-headless), Gateway, HTTPRoute
- All ExternalSecrets (keycloak-admin-secret, keycloak-postgres-secret, keycloak-pg-credentials)
- CNPG keycloak-pg: 3 instances, 10Gi, backup schedule, resources, affinity — all match
- MinIO: deployment, service, PVC, ExternalSecret — all match (except image registry)
- OAuth2-proxy: 3 instances (prometheus, alertmanager, hubble) — args, services, ExternalSecrets, middlewares all match
- setup-keycloak.sh: 10 OIDC clients, audience mappers, groups scope — mostly correct

### Phase 3: Bundle 3 — Monitoring

**Status**: DONE (platform-engineer complete)

#### 95%+ Match — Extremely Well Aligned

All core components match: Prometheus, Alertmanager, Grafana (HPA, OIDC, PostgreSQL backend), Loki, Alloy configs are MD5-identical to code. All 30 ServiceMonitors, 22 PrometheusRules, 26 custom dashboards, 3 VolumeAutoscalers traced to code files.

#### Gaps Found

| Component | Issue | Severity |
|-----------|-------|----------|
| All kube-prometheus-stack images | Pull directly from upstream (quay.io, docker.io, registry.k8s.io) instead of Harbor pull-through cache | HIGH |
| Loki + Alloy images | `docker.io/grafana/...` — not via Harbor | HIGH |
| Grafana Service sessionAffinity | **Triple mismatch**: Code=1800s, Helm=10800s, live Service=14400s (kubectl-patch override). Next `helm upgrade` will reset to code value. | MEDIUM |
| Orphaned code file | `service-monitor-cluster-autoscaler.yaml` not in any kustomization, not applied. Dashboard ConfigMap IS deployed but has no data source. | LOW |
| Keycloak dashboard | `configmap-dashboard-keycloak.yaml` exists in code but not deployed (likely skipped in Bundle 2 Phase 8) | LOW |

### Phase 4: Bundle 4 — Harbor

**Status**: DONE

#### HIGH Findings

| Component | Issue |
|-----------|-------|
| Harbor HPAs (3) | `hpa-core.yaml`, `hpa-registry.yaml`, `hpa-trivy.yaml` defined in code, Phase 7 applies them, but **NONE exist on cluster**. Phase 7 was not run or failed silently. |
| Harbor VolumeAutoscalers (3) | `volume-autoscalers.yaml` defines CRs for harbor-minio, harbor-pg, harbor-valkey but `deploy-harbor.sh` **never applies this file** in any phase. Need to add to script. |
| MANIFEST.yaml image tags stale | All 7 Harbor images say v2.14.0 but chart 1.18.2 deploys v2.14.2 |
| vault-root-ca ConfigMap | Exists in harbor namespace but no source YAML or deploy script phase creates it |

#### MEDIUM — CNPG Image Registry Drift

Code correctly uses Harbor pull-through (`harbor.example.com/proxy-ghcr/...`) but live cluster uses direct `ghcr.io/...`. Code is correct per conventions — live needs re-apply.

#### Harbor Deep-Dive Re-Audit (post Redis fix)

**harbor-jobservice**: FIXED — 2/2 replicas running, 0 restarts, Redis connectivity working via Sentinel.

**Valkey/Redis post-fix status**: Fully healthy. Master (harbor-redis-0) + 2 slaves, replication lag 0-1, Sentinel quorum intact (2 sentinels, `mymaster` group). Auth working via `password` key from ExternalSecret.

**NEW CRITICAL finding**: Harbor Helm release (revision 14) was deployed with **all 4 credential sets inline** (admin password, DB password, S3 access/secret keys, Redis password) instead of the `existingSecret*` pattern defined in code. The 3 ExternalSecrets in `external-secrets.yaml` (admin, DB, S3) were **never applied** to the cluster. Only `harbor-valkey-credentials` exists. Passwords are in plaintext in Helm release secrets (etcd).

**Helm revision 14**: 14 re-deploys during Redis troubleshooting. 25 stale ReplicaSets (scaled to 0).

**CNPG harbor-pg**: Healthy — 3/3 instances, backups working (last success 02:00 UTC), continuous archiving operational. Image uses direct `ghcr.io` instead of Harbor proxy-cache.

#### Verified Accurate

- All Harbor deployments, StatefulSets, services match Helm values
- Gateway + HTTPRoute at harbor.dev.example.com — correct
- Valkey Redis (RedisReplication + RedisSentinel) — 3 replicas, match code
- All ExternalSecrets (harbor-valkey-credentials, harbor-pg-credentials, cnpg-minio-credentials)
- CNPG harbor-pg: 3 instances, 20Gi, backup schedule
- All monitoring (2 ServiceMonitors, 2 PrometheusRules, 2 Grafana dashboards) — match
- MinIO S3 integration (endpoint, accesskey, bucket) — correct

### Phase 5: Bundle 5 — GitOps

**Status**: DONE (platform-engineer complete)

#### HIGH Findings

| Component | Issue |
|-----------|-------|
| ArgoCD `argocd-cm` rootCA | Live has `rootCA` in OIDC config (required for Keycloak TLS). Helm values do NOT — next `helm upgrade` will **strip the rootCA** and break OIDC |
| Argo Workflows ExternalSecret | `oauth2-proxy-workflows` ExternalSecret exists live + synced, but **NO code file** — needs `external-secret-oauth2-proxy.yaml` created |
| ArgoCD `server.insecure` conflict | ConfigMap says `false`, container arg says `--insecure`. Use `configs.params` instead of `extraArgs` |

#### MEDIUM Findings

| Component | Issue |
|-----------|-------|
| ArgoCD HPA memory target | Live has memory 50% target, code only specifies CPU 70%. Add `targetMemoryUtilizationPercentage: 50` |
| ArgoCD RBAC matchMode | Live has `policy.matchMode: glob`, not in values |
| ArgoCD TLS certs CM | `keycloak.example.com` CA trust in `argocd-tls-certs-cm` not in Helm values |
| Rollouts trafficRouterPlugins | `CHANGEME_ARGO_ROLLOUTS_PLUGIN_URL` not set in `.env` — results in empty config |
| MANIFEST.yaml stale refs | 4 references to removed `middleware-basic-auth.yaml`, missing workflows OAuth2-proxy files |
| Argo VolumeAutoscaler | `volume-autoscalers.yaml` in code but never applied by deploy script |

#### LOW Findings

- `external-secret-redis.yaml` in rollouts — unused (cookie sessions), should be removed
- OAuth2-proxy args drift (rollouts + workflows): live missing `--cookie-expire`, `--cookie-refresh`, `--metrics-address` vs code — code is ahead, needs re-apply

#### Verified Accurate

- All 3 Helm releases match pinned versions (ArgoCD 7.8.8, Rollouts 2.39.1, Workflows 0.45.1)
- All deployments, StatefulSets match (replicas, resources, images)
- All Gateways, HTTPRoutes, Middlewares, Certificates match
- All 3 ClusterAnalysisTemplates match
- All monitoring (3 ServiceMonitors, 1 PrometheusRule, 3 dashboards) match

### Phase 6: Bundle 6 — Git & CI

**Status**: DONE

#### HIGH Findings

| Component | Issue |
|-----------|-------|
| PgBouncer poolers | `pgbouncer-poolers.yaml` exists and poolers run live, but `deploy-gitlab.sh` has NO step to apply them — deployed manually |
| Redis images not via Harbor | `replication.yaml` uses `quay.io/opstree/redis:v7.0.15`, `sentinel.yaml` uses `quay.io/opstree/redis-sentinel:v7.0.15`, exporter uses `oliver006/redis_exporter:v1.66.0` — all direct pulls |
| `gitlab-minio-storage` secret | Created manually, not managed by ExternalSecret or deploy script — gap in GitOps model |
| CNPG image drift | Code correctly uses Harbor proxy, live uses direct `ghcr.io/...` — needs re-apply |

#### MEDIUM Findings

| Component | Issue |
|-----------|-------|
| MANIFEST.yaml | Missing pgbouncer-poolers.yaml from resources, image refs not using Harbor proxy |
| No Helm chart version pinning | GitLab chart (9.9.2) and runner chart (0.86.0) not version-pinned in deploy script |

#### Verified Accurate

- All Helm values match after CHANGEME substitution (full comparison)
- All 6 ExternalSecrets in gitlab namespace match code
- All 3 runner Helm releases (shared, security, group) — tags, executor, nodeSelector, RBAC match
- Gateway (3 listeners), HTTPRoutes (gitlab, kas), TCPRoute (ssh) — all match
- CNPG gitlab-postgresql: 3 instances, 50Gi, backup, poolers — spec matches (image drift only)
- Redis: 3 replicas + Sentinel, storage, nodeSelector, anti-affinity — all match
- All monitoring (3 ServiceMonitors, 1 PodMonitor, 2 PrometheusRules, 2 dashboards) — all match

### Phase 10: Documentation Sync

**Status**: DONE

#### Critical Documentation Issues

| Document | Issue | Severity |
|----------|-------|----------|
| README.md + MEMORY.md | Node count says "12 nodes" but cluster has **13 nodes** (3 CP, 4 DB, 4 general, 2 compute) | CRITICAL |
| README.md | Redis operators listed as "pre-installed" requirement but NO installation instructions anywhere | CRITICAL |
| docs/architecture.md | Missing `grafana-pg` from CNPG clusters list (5 clusters, not 4) | HIGH |
| services/harbor/README.md | Missing Spotahome Redis Operator prerequisite | HIGH |
| services/gitlab/README.md | Missing OpsTree Redis Operator prerequisite | HIGH |
| Hubble README | References `hubble.dev.example.com` but live uses `hubble.example.com` | MEDIUM |

#### Verified Accurate

- All deploy script phase counts match (7, 8+6, 6, 8, 7, 9)
- Architecture Mermaid diagrams use correct GitLab-compatible HTML entities
- Service dependencies and network flows documented accurately
- Bundle deployment order in README matches actual dependency chain

---

## Action Items

| ID | Severity | Bundle | Description | Status |
|----|----------|--------|-------------|--------|
| A01 | CRITICAL | 0 | Cilium HelmChartConfig: Hubble config stripped by RKE2 controller — relay runs 1 replica, no resources, no nodeSelector. Need alternative approach (direct Helm values or post-apply patch) | TODO |
| A02 | CRITICAL | 0 | oauth2-proxy-traefik: Re-apply deployment to pick up 3 missing args (cookie-expire, cookie-refresh, metrics-address) | TODO |
| A03 | HIGH | 0 | Create `deploy-traefik-dashboard.sh` script or add kustomization.yaml for `services/traefik-dashboard/` | TODO |
| A04 | HIGH | 0 | Add CNPG operator HPA + PDB manifests to repo (currently live but not in code) | TODO |
| A05 | HIGH | 0 | Fix CNPG operator nodeSelector: code says `general`, live has `database` — update code to match live | TODO |
| A06 | MEDIUM | 0 | Document pre-bundle operator dependencies (redis-operator, storage-autoscaler, node-labeler, cluster-autoscaler) as external Terraform prerequisites | TODO |
| A07 | CRITICAL | docs | Fix node count: 12 → 13 in README.md and MEMORY.md | TODO |
| A08 | HIGH | docs | Add Redis operator installation instructions to docs/getting-started.md | TODO |
| A09 | HIGH | docs | Add grafana-pg to CNPG clusters list in docs/architecture.md | TODO |
| A10 | MEDIUM | docs | Fix Hubble hostname in service README (remove `dev.` prefix) | TODO |
| A11 | MEDIUM | 1 | Add VolumeAutoscaler CRs for Vault PVCs `data-vault-{0,1,2}` (threshold 80%, maxSize ~50Gi) | TODO |
| A12 | LOW | 1 | Add `--set cainjector.nodeSelector.workload-type=general --set webhook.nodeSelector.workload-type=general` to cert-manager install in `deploy-pki-secrets.sh` | TODO |
| A13 | LOW | 1 | Apply namespace YAML manifests before Helm installs (or remove unused label definitions from namespace.yaml files) | TODO |
| A14 | RESOLVED | 1 | ~~Route Vault/cert-manager/ESO images through Harbor~~ — RKE2 `registries.yaml` rewrites all image pulls through `harbor.example.com` at containerd level. No YAML changes needed. | N/A |
| A15 | CRITICAL | 2 | Fix CNPG operator deployment name in `deploy-keycloak.sh:123`: `cnpg-cloudnative-pg` → `cnpg-controller-manager` | TODO |
| A16 | CRITICAL | 2 | Update CNPG operator Helm chart version from v0.23.0 to match live v1.28.1 (chart ~0.26.x) | TODO |
| A17 | HIGH | 2 | Fix CNPG operator nodeSelector in deploy script: `general` → `database` to match live | TODO |
| A18 | HIGH | 2 | Add container securityContext to prometheus + alertmanager OAuth2-proxy deployments (match hubble's hardening) | TODO |
| A19 | HIGH | 2 | Pin MinIO mc job image: `quay.io/minio/mc:latest` → specific version (e.g., `quay.io/minio/mc:RELEASE.2024-11-07T00-52-20Z`). RKE2 registries.yaml handles the Harbor rewrite, but `:latest` is still a bad practice — unresolvable if not cached. | TODO |
| A20 | HIGH | 2 | Apply Keycloak monitoring resources (ServiceMonitor, PrometheusRule, dashboard) — run deploy-keycloak.sh Phase 8 or apply manually | TODO |
| A21 | MEDIUM | 2 | Apply VolumeAutoscaler `keycloak-pg` — defined in code but not on cluster | TODO |
| A22 | MEDIUM | 2 | Update MANIFEST.yaml phase numbering to match actual 8-phase deploy script | TODO |
| A23 | MEDIUM | 2 | Consider moving MinIO manifests from `services/harbor/minio/` to `services/minio/` (shared service) | TODO |
| A24 | RESOLVED | 2 | ~~Route Bundle 2 images through Harbor~~ — RKE2 `registries.yaml` handles this at containerd level. No YAML changes needed. | N/A |
| A25 | HIGH | 2 | Create VolumeAutoscaler CR for MinIO `minio-data` PVC (200Gi, shared by all CNPG backups + Harbor + GitLab — grows monotonically, no autoscaler exists) | TODO |
| A26 | HIGH | 4 | Apply Harbor HPAs — run `deploy-harbor.sh` Phase 7 or manually apply `hpa-core.yaml`, `hpa-registry.yaml`, `hpa-trivy.yaml` | TODO |
| A27 | HIGH | 4 | Add VolumeAutoscaler apply step to `deploy-harbor.sh` (file exists but no phase applies it) | TODO |
| A28 | MEDIUM | 4 | Update `services/harbor/MANIFEST.yaml` image tags: v2.14.0 → v2.14.2 | TODO |
| A29 | MEDIUM | 4 | Add vault-root-ca ConfigMap creation to `deploy-harbor.sh` or document how it gets created | TODO |
| A30 | RESOLVED | 3 | ~~Route kube-prometheus-stack images through Harbor~~ — RKE2 `registries.yaml` handles this at containerd level. | N/A |
| A31 | RESOLVED | 3 | ~~Route Loki + Alloy images through Harbor~~ — RKE2 `registries.yaml` handles this at containerd level. | N/A |
| A32 | MEDIUM | 3 | Fix Grafana sessionAffinity triple mismatch: decide correct value, update code, remove kubectl-patch override | TODO |
| A33 | LOW | 3 | Either add `service-monitor-cluster-autoscaler.yaml` to kustomization or remove orphaned file | TODO |
| A34 | LOW | 3 | Apply Keycloak monitoring dashboard (already tracked in A20 for Bundle 2) | TODO |
| A35 | CRITICAL | 2 | Add securityContext to ALL non-hubble OAuth2-proxy deployments (prometheus, alertmanager, traefik, rollouts, workflows) — match hubble's hardening: runAsNonRoot, readOnlyRootFilesystem, drop ALL capabilities | TODO |
| A36 | HIGH | 2 | Restrict Keycloak admin console paths (`/admin/`, `/realms/master/`) via Traefik middleware or HTTPRoute rules | TODO |
| A37 | HIGH | 2 | Add `KC_DB_URL_PROPERTIES=sslmode=verify-full` to Keycloak deployment for TLS DB connections | TODO |
| A38 | MEDIUM | 2 | Add securityContext to MinIO deployment (currently has none — needs non-root, readOnlyRootFilesystem) | TODO |
| A39 | HIGH | 6 | Add PgBouncer pooler deployment step to `deploy-gitlab.sh` Phase 3 (`kubectl apply -f pgbouncer-poolers.yaml`) | TODO |
| A40 | RESOLVED | 6 | ~~Route GitLab Redis images through Harbor~~ — RKE2 `registries.yaml` handles this at containerd level. | N/A |
| A41 | HIGH | 6 | Create ExternalSecret for `gitlab-minio-storage` secret backed by Vault, or add creation to deploy script | TODO |
| A42 | MEDIUM | 6 | Update `services/gitlab/MANIFEST.yaml`: add pgbouncer-poolers.yaml to resources, fix image refs to Harbor proxy | TODO |
| A43 | MEDIUM | 6 | Pin Helm chart versions in deploy script: GitLab `--version 9.9.2`, runners `--version 0.86.0` | TODO |
| A44 | HIGH | 5 | Add `rootCA` to ArgoCD OIDC config in `argocd-values.yaml` — next helm upgrade will strip it and break OIDC | TODO |
| A45 | HIGH | 5 | Create `services/argo/argo-workflows/external-secret-oauth2-proxy.yaml` — live ExternalSecret has no code file | TODO |
| A46 | HIGH | 5 | Fix ArgoCD `server.insecure`: use `configs.params."server.insecure": true` instead of `extraArgs: [--insecure]` | TODO |
| A47 | MEDIUM | 5 | Add `targetMemoryUtilizationPercentage: 50` to ArgoCD server + repoServer HPA values | TODO |
| A48 | MEDIUM | 5 | Add `policy.matchMode: glob` to ArgoCD `configs.rbac` in values | TODO |
| A49 | MEDIUM | 5 | Add `configs.tls.certificates` for keycloak.example.com CA trust in ArgoCD values | TODO |
| A50 | MEDIUM | 5 | Fix Rollouts `trafficRouterPlugins`: set `ARGO_ROLLOUTS_PLUGIN_URL` in `.env` or remove block | TODO |
| A51 | MEDIUM | 5 | Clean up `services/argo/MANIFEST.yaml`: remove 4 stale basic-auth refs, add workflows OAuth2-proxy files | TODO |
| A52 | LOW | 5 | Apply Argo VolumeAutoscaler — add to deploy script phase | TODO |
| A53 | LOW | 5 | Remove unused `services/argo/argo-rollouts/external-secret-redis.yaml` | TODO |
| A54 | CRITICAL | 4 | Harbor Helm release deployed with **4 inline credentials** (admin password, DB password, S3 keys, Redis password) — code correctly defines `existingSecret*` refs but live Helm state has plaintext passwords in etcd. Must: (1) apply 3 missing ExternalSecrets from `external-secrets.yaml`, (2) re-deploy with `existingSecret*` pattern, (3) rotate all 4 credentials in Vault | TODO |
| A55 | CRITICAL | 4 | `scripts/utils/subst.sh` lines 19-22: empty defaults for secret vars — add `:?` fail-if-empty guards to prevent silent empty-password deployments | TODO |
| A56 | HIGH | 4+5 | Deploy scripts (`deploy-harbor.sh:139`, `deploy-argo.sh:145`) use Vault root token — should use AppRole or limited-privilege token | TODO |
| A57 | HIGH | 5 | ArgoCD admin account not disabled — add `configs.params."accounts.admin.enabled": false` | TODO |
| A58 | HIGH | 5 | ArgoCD Redis HA uses `valkey:8-alpine` floating tag — pin to specific semver (e.g., `valkey:8.0.2-alpine`). RKE2 registries.yaml handles the Harbor rewrite, but floating tags risk pulling uncached versions. | TODO |
| A59 | MEDIUM | 4 | Harbor Valkey sentinel has no `requirepass` — password auth not enforced | TODO |
| A60 | MEDIUM | 4 | Harbor Valkey replication.yaml missing container securityContext | TODO |
| A61 | MEDIUM | 5 | Argo Rollouts dashboard missing container securityContext | TODO |
| A62 | MEDIUM | 5 | Argo Workflows `readOnlyRootFilesystem: false` and `auth-mode: server` (no auth) | TODO |
| A63 | LOW | 5 | `deploy-argo.sh` has dead basic-auth imports at lines 13, 36-38 — remove stale references | TODO |
| A64 | HIGH | 4 | Add VolumeAutoscaler for `harbor-trivy` PVC — only PVC in Harbor without autoscaler | TODO |
| A65 | HIGH | 6 | Add VolumeAutoscaler for 3x Gitaly PVCs (`repo-data-gitaly-{0,1,2}`, 100Gi each) — no autoscaler exists | TODO |
| A66 | HIGH | 5 | Add PDBs for ArgoCD stateless workloads: server, repo-server, applicationset-controller, notifications-controller | TODO |
| A67 | HIGH | 5 | Add PDB for Argo Rollouts controller (currently single replica, no PDB) | TODO |
| A68 | HIGH | 4 | Add PDBs for Harbor stateless workloads: core, registry, portal, jobservice | TODO |
| A69 | MEDIUM | 4 | Investigate Harbor HPAs not persisting — `deploy-harbor.sh` Phase 7 applies but HPAs don't exist live. Check for Helm ownership conflicts or Phase 7 execution failure | TODO |
| A70 | MEDIUM | 5 | Add resource requests to ArgoCD Redis HA split-brain-fix container (currently no resources defined) | TODO |
| A71 | LOW | 6 | Consider raising GitLab sidekiq HPA maxReplicas from 10 → 15 (currently at 8/10, approaching saturation) | TODO |
| A72 | HIGH | 1 | Add ForwardAuth/OAuth2-proxy protection to Vault UI Gateway — currently exposed without authentication middleware | TODO |
| A73 | MEDIUM | 1 | Add explicit `duration: 720h` and `renewBefore: 168h` to all 13 cert-manager Certificate resources (currently relying on defaults, not matching 30-day leaf cert standard) | TODO |
| A74 | MEDIUM | 1 | `vault.sh` uses `eval` for Vault CLI — review for injection risk, consider replacing with direct command execution | TODO |
| A75 | MEDIUM | 1 | vault-root-ca ConfigMaps exist in 9 namespaces but only 3 created by deploy scripts — add remaining 6 to appropriate deploy scripts for reproducibility | TODO |
| A76 | CRITICAL | 1 | **AIRGAP BLOCKER**: `deploy-pki-secrets.sh` fetches Gateway API CRDs from `raw.githubusercontent.com` — download and store in `scripts/manifests/`, update script to `kubectl apply -f` from local path | TODO |
| A77 | HIGH | all | **AIRGAP**: `.env.example` has `HELM_REPO_*`/`HELM_CHART_*` overrides (correct pattern) but users must uncomment+set them. Add a clearly marked `## Airgap / Private Registry` section with all required overrides, including `HELM_REPO_CNPG` which is missing from .env.example | TODO |
| A78 | HIGH | 5 | ArgoCD/Rollouts/Workflows OCI charts from `oci://ghcr.io/argoproj/...` — `.env.example` has `HELM_CHART_*` overrides (lines 75-77). Ensure user sets these for airgap to point to Harbor OCI proxy or charts.example.com-synced artifacts | TODO |
| A79 | HIGH | 4 | Harbor OCI chart from `oci://registry-1.docker.io/goharbor/...` — `.env.example` has override (line 52). Ensure user sets for airgap. Already synced via charts.example.com | TODO |
| A80 | RESOLVED | all | ~~Container image registry rewrite~~ — RKE2 `registries.yaml` mirrors all upstream registries (docker.io, quay.io, ghcr.io, registry.k8s.io, gcr.io, docker.elastic.co, registry.gitlab.com) through `harbor.example.com` with rewrite rules at containerd level. No YAML changes needed. | N/A |
| A81 | RESOLVED | 0 | ~~Traefik dashboard alpine image~~ — covered by RKE2 registries.yaml docker.io mirror. | N/A |
| A82 | CRITICAL | 4 | 3 Harbor ExternalSecrets never applied (`harbor-admin-credentials`, `harbor-db-credentials`, `harbor-s3-credentials`) — `kubectl apply -f services/harbor/external-secrets.yaml` then re-deploy Helm with `existingSecret*` pattern | TODO |
| A83 | HIGH | 4 | harbor-core and harbor-registry running as **single replica** (no HA) — HPAs not deployed, voluntary disruption = downtime | TODO |
| A84 | MEDIUM | 4 | 25 stale scaled-to-0 ReplicaSets in harbor namespace — cleanup after Redis fix stabilizes | TODO |
| A85 | MEDIUM | 4 | Add VolumeAutoscaler CR for harbor-trivy PVC (`data-harbor-trivy-0`, 5Gi) — not in code or live | TODO |
| A86 | HIGH | all | **AIRGAP**: Add `PRIVATE_CA_CERT` / `CA_BUNDLE_PATH` env var to `.env.example` — users providing their own PKI root CA need a documented way to inject it into vault-root-ca ConfigMaps, Keycloak truststore, ArgoCD TLS certs, etc. | TODO |
| A87 | RESOLVED | 1 | ~~Gateway API CRDs~~ — merged into A76 (download to `scripts/manifests/`) | N/A |
| A88 | HIGH | 5 | **AIRGAP**: Argo Rollouts plugin URL (`ARGO_ROLLOUTS_PLUGIN_URL`) defaults to GitHub release — `.env.example` has the override (line 80) but it's commented out with no airgap guidance | TODO |

---

## Reproducibility Verdict

**PARTIALLY REPRODUCIBLE — 88 action items total (8 RESOLVED via RKE2 registries.yaml, 80 actionable: 10 CRITICAL, 28 HIGH, 20 MEDIUM, 8 LOW).**

> **Note:** RKE2 `registries.yaml` on all nodes mirrors docker.io, quay.io, ghcr.io, registry.k8s.io, gcr.io, docker.elastic.co, and registry.gitlab.com through `harbor.example.com` at the containerd level. Container image references in YAML manifests do NOT need rewriting. Helm chart repos use `.env` overrides (`HELM_REPO_*`/`HELM_CHART_*`) for airgap.

### Summary

The codebase captures ~85% of the live cluster state's *logic*, but **cannot produce a working deployment in an airgapped environment**. The fundamental blocker: 40+ container images, 6 Helm chart repos, 2 OCI chart references, and 2 GitHub CRD URLs all point to the public internet. In the airgapped cluster, these currently work because images were cached in Harbor during initial setup when the network was available — but a fresh deploy from this codebase would fail immediately.

#### Blocking Issues — Airgap (fresh deploy would FAIL)

1. **GitHub CRD fetch** (A76) — Gateway API CRDs fetched from raw.githubusercontent.com — must download to `scripts/manifests/`
2. **Helm repos default to internet** (A77) — users must set `HELM_REPO_*`/`HELM_CHART_*` in `.env` (overrides exist but `HELM_REPO_CNPG` is missing)
3. ~~Images~~ — **RESOLVED**: RKE2 `registries.yaml` rewrites all image pulls through Harbor at containerd level

#### Blocking Issues — Logic (fresh deploy would FAIL even with internet)

1. **CNPG operator deployment name mismatch** (A15) — `wait_for_deployment` polls wrong name, deploy hangs
2. **CNPG operator version downgrade** (A16) — would install v1.25.0 over live v1.28.1
3. **Harbor 3 ExternalSecrets never applied** (A82) + **inline credentials in Helm state** (A54) — passwords in plaintext in etcd
4. **`subst.sh` empty defaults** (A55) — would deploy with blank passwords
5. **ArgoCD OIDC rootCA** (A44) — next `helm upgrade` strips rootCA, breaks Keycloak SSO

#### Drift Categories

| Category | Count | Impact |
|----------|-------|--------|
| **Airgap (CRDs, Helm repo env vars)** | **3** | **CRDs: FATAL. Helm repos: user must set .env** |
| ~~Image registry~~ (RESOLVED by registries.yaml) | ~~8~~ → 0 | RKE2 containerd mirrors handle this |
| Missing resources (VolumeAutoscalers, HPAs, PDBs) | 15 | Operational: no auto-scaling, no disruption protection |
| Security hardening gaps (securityContext, passwords, credentials) | 10 | Security: inline creds in Helm state, inconsistent hardening |
| Config drift (code behind live state) | 10 | Drift: helm upgrade would regress live state |
| Deploy script bugs / missing steps | 8 | Reproducibility: manual steps required |
| Documentation inaccuracies | 6 | Operational: misleading docs |
| Stale references / cleanup | 7 | Maintenance: dead code, wrong versions |
| Missing code files for live resources | 3 | Reproducibility: cannot recreate from code |

#### Recommended Priority Order

1. **CRITICAL (18 items)**: A01, A02, A07, A14, A15, A16, A19, A24, A30, A31, A40, A54, A55, A58, A76, A77, A78, A79, A80, A81 — airgap blockers + logic failures
2. **HIGH (23 items)**: Deploy script fixes, security hardening, PDBs, VolumeAutoscalers
3. **MEDIUM (18 items)**: Config alignment, MANIFEST updates, operational improvements
4. **LOW (7 items)**: Cleanup, minor drift, cosmetic
5. **INFO (3 items)**: Observations, no action required

#### Airgap Infrastructure

A dedicated proxy VM (`harvester-helm-harbor-sync` repo) provides all external resources:

| Internal Hostname | Purpose | Upstream |
|-------------------|---------|----------|
| `harbor.example.com` | Container images (proxy-cache) + OCI Helm charts | docker.io, quay.io, ghcr.io, registry.k8s.io |
| `charts.example.com` | HTTP Helm chart repos (nginx proxy + helm-sync to Harbor OCI) | jetstack, hashicorp, prometheus-community, etc. |
| `yum.example.com` | Rocky 9 RPM repos, EPEL, RKE2 RPMs | mirrorlist.rockylinux.org, etc. |

#### Airgap Remediation Strategy

**Container images** — handled by RKE2 `registries.yaml` (no YAML changes needed):

| Mirror | Endpoint | Rewrite |
|--------|----------|---------|
| docker.io | harbor.example.com | `docker.io/$1` |
| quay.io | harbor.example.com | `quay.io/$1` |
| ghcr.io | harbor.example.com | `ghcr.io/$1` |
| registry.k8s.io | harbor.example.com | `registry.k8s.io/$1` |
| gcr.io | harbor.example.com | `gcr.io/$1` |
| docker.elastic.co | harbor.example.com | `docker.elastic.co/$1` |
| registry.gitlab.com | harbor.example.com | `registry.gitlab.com/$1` |
| docker-registry3.mariadb.com | harbor.example.com | `docker-registry3.mariadb.com/$1` |

> This is configured per-node via Rancher/Terraform cloud-init. All container image pulls are transparently redirected to Harbor proxy-cache projects at the containerd level. Manifests can reference upstream registries directly.

**HTTP Helm chart repos** — rewrite `HELM_REPO_*` vars to use `charts.example.com`:

| Current (internet) | Airgap (proxy) |
|---------------------|----------------|
| `https://charts.jetstack.io` | `https://charts.example.com/jetstack` |
| `https://helm.releases.hashicorp.com` | `https://charts.example.com/hashicorp` |
| `https://charts.external-secrets.io` | `https://charts.example.com/external-secrets` |
| `https://helm.goharbor.io` | `https://charts.example.com/goharbor` |
| `https://prometheus-community.github.io/helm-charts` | `https://charts.example.com/prometheus-community` |
| `https://cloudnative-pg.github.io/charts` | `https://charts.example.com/cnpg` |
| `https://charts.gitlab.io` | `https://charts.example.com/gitlab` |

**OCI Helm charts** — pull through Harbor proxy-cache:

| Current (internet) | Airgap (Harbor OCI) |
|---------------------|---------------------|
| `oci://ghcr.io/argoproj/argo-helm/argo-cd` | `oci://harbor.example.com/proxy-ghcr/argoproj/argo-helm/argo-cd` |
| `oci://registry-1.docker.io/goharbor/harbor-helm` | Already synced via charts.example.com/goharbor |

**CRDs** — download and store in `scripts/manifests/`:

| Current | Fix |
|---------|-----|
| `kubectl apply -f https://raw.githubusercontent.com/.../tcproutes.yaml` | Download to `scripts/manifests/gateway.networking.k8s.io_tcproutes.yaml` |
| `kubectl apply -f https://raw.githubusercontent.com/.../tlsroutes.yaml` | Download to `scripts/manifests/gateway.networking.k8s.io_tlsroutes.yaml` |
| Update `deploy-pki-secrets.sh` | `kubectl apply -f "${SCRIPT_DIR}/manifests/"` |

### Script Execution Order (from README)

1. `deploy-pki-secrets.sh` (7 phases)
2. `deploy-keycloak.sh` (8 phases) + `setup-keycloak.sh` (6 phases)
3. `deploy-monitoring.sh` (6 phases)
4. `deploy-harbor.sh` (8 phases)
5. `deploy-argo.sh` (7 phases)
6. `deploy-gitlab.sh` (9 phases)

**Additional scripts not in README bundle order:**
- `deploy-hubble.sh` — Hubble observability (kube-system)

### Pre-bundle dependencies (must exist before Bundle 1)

- cnpg-system (CNPG operator)
- redis-operator
- storage-autoscaler
- node-labeler
- cluster-autoscaler
- Cilium CNI (rke2-cilium HelmChartConfig)
- Traefik ingress (rke2-traefik HelmChartConfig)
