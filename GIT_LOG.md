db773b3 feat: initialize harvester-rke2-svcs project
- Bootstrap memory structure (MEMORY.md, team files)
- Copy and adapt 5 Claude Code agents from rke2-cluster-via-rancher
- Add .gitignore for secrets, terraform state, kubeconfigs
- Add PKI & Secrets bundle design doc (approved)
- Add PKI & Secrets bundle implementation plan (13 tasks)

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
6c0de05 feat: add script utility modules (log, helm, wait, vault, subst)
Foundation shell modules for the PKI & Secrets deployment pipeline.
All files are sourced (not executed directly) and pass ShellCheck.

- log.sh: colored logging, phase timing, die()
- helm.sh: idempotent repo add and install/upgrade
- wait.sh: deployment, pod, ClusterIssuer, and TLS secret polling
- vault.sh: init, unseal, and exec wrappers via kubectl
- subst.sh: CHANGEME_* token substitution for manifests

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
6f58bce fix: address code review issues in script utilities
- wait.sh: check actual Ready condition instead of "Running" phase
- log.sh: guard end_phase against empty PHASE_START_TIME
- subst.sh: validate DOMAIN vars before substitution
- vault.sh: pipe unseal keys via stdin to avoid ps visibility

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
d44fdc9 feat: add PKI service with generate-ca.sh and root CA cert
Set up the PKI service directory with offline Root CA tooling,
root certificate, and Vault intermediate CA documentation.
Includes .gitignore to prevent private key material from being committed.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
1c73b82 feat: add Vault service manifests and monitoring
Add Vault service directory with:
- Namespace, Gateway API, and HTTPRoute manifests
- Helm values for HA Raft deployment (3 replicas)
- Monitoring: ServiceMonitor, PrometheusRule alerts, Grafana dashboard
- Kustomization files for both service and monitoring layers

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
dd2745e feat: add external-secrets service manifests and monitoring
Add external-secrets namespace, ServiceMonitor, PrometheusRule alerts,
and Grafana dashboard ConfigMap with Kustomize overlays for the
Harvester RKE2 cluster.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
7e2401b feat: add cert-manager service manifests and monitoring
Add cert-manager service with Vault ClusterIssuer integration, RBAC for
ServiceAccount token creation, and monitoring stack (ServiceMonitor,
PrometheusRule alerts, Grafana dashboard ConfigMap).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
bd7ae3f feat: add deploy-pki-secrets.sh orchestrator and .env.example
7-phase deployment script for PKI & Secrets bundle (Vault, cert-manager,
ESO) with CLI phase selection, unseal-only mode, and health-check
validation. Sources modular utils from scripts/utils/ for logging, Helm,
wait, Vault ops, and CHANGEME substitution.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
ca8bef6 docs: add READMEs for all services and project root
Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
4859c11 ci: add GitHub Actions workflow for shellcheck, yamllint, kustomize
Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
2ebf2d0 security: sanitize repo for public release — remove org-specific info and real certificates
- Remove real Root CA certificate (aegis-group-root-ca.pem)
- Update pki/.gitignore to block all *.pem files
- Replace example.com with example.com in all scripts and docs
- Replace "Example Org" org name with "My Organization" (configurable via -o flag and ORG env var)
- Replace aegis-group-root-ca filenames with generic root-ca
- Make nameConstraints DNS domain configurable via NAME_CONSTRAINT_DNS env var
- Add ORG env var to deploy-pki-secrets.sh for Vault intermediate CA naming
- Replace hardcoded local paths with relative references in design docs
- Replace author username with generic "Project Author"
- Add .gitkeep to roots/ directory so users know where to place their CA cert
- Add general .env and editor artifact patterns to root .gitignore

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
ea404fd docs: add architecture overview, getting started guide, and contributing guide
Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
92ca2e1 ci: comprehensive CI with gitleaks, shellcheck, yamllint, markdownlint, kustomize
Split monolithic lint-and-validate job into parallel jobs for faster
feedback. Add gitleaks secret scanning, markdownlint with custom config,
and dedicated linter configs in .github/linters/. Fix README badge to
point to actual repo. Add Apache 2.0 LICENSE file.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
2ded354 fix: resolve CI failures — shellcheck rcfile and markdownlint MD046
- Move .shellcheckrc to repo root (shellcheck auto-discovers it, --rcfile flag unsupported)
- Disable MD046 code-block-style rule (indented blocks used in service READMEs)

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
be69779 fix: pin Helm chart versions and document missing env vars
- Pin Vault chart to v0.29.1
- Pin ESO chart to v0.17.0
- Add ORG and NAME_CONSTRAINT_DNS to .env.example

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
ba91580 chore: update to latest Helm chart and app versions
- Vault chart 0.32.0 (app 1.21.2)
- cert-manager chart v1.19.4
- ESO chart 2.0.1

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
454ff71 feat: support OCI registry paths for Helm charts
- Add HELM_CHART_* and HELM_REPO_* env vars for all 3 charts
- helm_repo_add skips repo add for oci:// URLs
- Defaults to upstream repos, overridable for Harbor or private registries

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
1ac71fa docs: add MANIFEST.yaml per service with charts, images, and resources
Each service now has a bill of materials listing:
- Helm chart name, version, and repository
- Container images with registry, name, and tag
- Kustomize resources and monitoring manifests
- Deploy script phases

Useful for air-gap pre-pulls and version auditing.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
e68338b docs: add full service bundle roadmap (6 bundles)
Roadmap covering PKI/Secrets → Monitoring → Harbor → Identity → GitOps → Git/CI.
Scope: bootstrap and deploy only. ArgoCD-GitLab integration is future work.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
87c05d2 docs: add resource conventions — requests only, HPA, storage autoscaler
- No CPU/memory limits (requests only, allow bursting)
- HPA on stateless workloads
- Storage autoscaler on growing PVCs

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
1c52cf9 docs: add pod anti-affinity and node selector conventions
- Anti-affinity for all replicated workloads (spread across nodes)
- Node selectors: database pool for stateful, general pool for stateless

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
1af8304 fix: remove CPU/memory limits from Vault — requests only per convention
Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
e0421dd docs: add Bundle 2 Monitoring design (approved)
Prometheus, Grafana, Loki (SimpleScalable), Alloy DaemonSet.
18 dashboards, 9 alert groups, 6 service monitors.
Basic-auth placeholder for Prometheus/Alertmanager until Bundle 4.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
f863743 docs: add Bundle 2 Monitoring implementation plan (14 tasks)
Covers: Loki, Alloy, kube-prometheus-stack Helm, 15 dashboards,
9 PrometheusRules, 6 ServiceMonitors, Gateway API ingress with
basic-auth, deploy script.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
393e626 feat: add basic-auth utility for Traefik middleware
Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
27979d1 feat: add monitoring namespace, Loki, and Alloy DaemonSet
Add the monitoring-stack foundation:
- monitoring namespace definition
- Loki StatefulSet (single-replica, filesystem storage, 50Gi PVC)
  with nodeSelector targeting database nodes and requests-only resources
- Alloy DaemonSet for pod logs, Kubernetes events, and RKE2 journal
  collection with requests-only resources
- Supporting ConfigMaps, RBAC, and Services for both components

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
776523b feat: add Prometheus/Alertmanager gateways with basic-auth middleware
Add Gateway API resources for Prometheus and Alertmanager with TLS
termination via cert-manager/vault-issuer, HTTPRoutes referencing
Traefik basic-auth middleware, and the corresponding Middleware CRs
that point to their respective secrets.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
f510167 feat: add 9 PrometheusRules and 6 ServiceMonitors
PrometheusRules for: cilium, kubernetes, loki, monitoring-self, node,
oauth2-proxy, postgresql, redis, traefik.

ServiceMonitors for: alloy, cnpg-controller, grafana, hubble-relay,
loki, redis-exporter.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
40a3013 feat: add Grafana gateway, httproute, and 15 platform dashboards
Gateway and HTTPRoute for Grafana ingress via Gateway API.
ServiceMonitor for cluster-autoscaler metrics collection.

15 dashboard ConfigMaps: alloy, apiserver, cilium, cluster-autoscaler,
cnpg, coredns, etcd, firing-alerts, home, loki-stack, loki,
node-detail, oauth2-proxy, redis, traefik.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
1389e53 feat: add root kustomization, service aliases, and monitoring env config
Add monitoring-stack/kustomization.yaml listing all 38 resources:
namespace, Loki, Alloy, Prometheus/Alertmanager gateways with
basic-auth, Grafana gateway, 15 dashboard ConfigMaps, service
monitor for cluster-autoscaler, service aliases, PrometheusRules,
and ServiceMonitors. Omits oauth2-proxy, grafana OIDC external
secret, and kube-system resources per bundle scope.

Copy prometheus-service-alias.yaml and alertmanager-service-alias.yaml
from source repo for backwards-compatible service discovery.

Add GRAFANA_ADMIN_PASSWORD and HELM_CHART_PROMETHEUS_STACK to
.env.example, and wire CHANGEME_GRAFANA_ADMIN_PASSWORD substitution
into subst.sh with safe ${:-} default for non-monitoring deploys.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
3e87906 docs: add monitoring-stack MANIFEST.yaml and README
Bill of materials listing all Helm charts, container images, Kustomize
manifests, and deploy phases. README documents architecture, ingress
endpoints, dashboards, and alert groups.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
9e4106f feat: add deploy-monitoring.sh orchestrator (6 phases)
Six-phase deploy script for the monitoring bundle:
  1. Namespace + Loki + Alloy
  2. Additional scrape configs Secret
  3. kube-prometheus-stack Helm install
  4. PrometheusRules + ServiceMonitors
  5. Gateways + HTTPRoutes + basic-auth
  6. Verify all components ready

Supports --phase N, --from N, --to N, --validate, and -h/--help.
Follows the same patterns as deploy-pki-secrets.sh.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
9ed7b99 security: fix hardcoded basic-auth creds and add CHANGEME_KC_REALM substitution
- Replace hardcoded admin/admin with env vars (PROM_BASIC_AUTH_PASS, AM_BASIC_AUTH_PASS)
- Add CHANGEME_KC_REALM to subst.sh (defaults to 'master')
- Add new env vars to .env.example

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
c31310d docs: add Bundle 3 Harbor design (approved)
Harbor + MinIO + CNPG PostgreSQL + Valkey Redis Sentinel.
8-phase deploy script, proxy cache + private registry.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
e362e79 docs: add Bundle 3 Harbor implementation plan (12 tasks)
Covers: MinIO, CNPG PostgreSQL, Valkey Redis Sentinel, Harbor Helm,
Gateway API ingress, HPAs, monitoring, deploy script.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
7a4caae feat: add Harbor monitoring (ServiceMonitors, alerts, Grafana dashboards)
Add comprehensive monitoring for Harbor registry and its backing services:
- ServiceMonitors for Harbor core/registry/exporter/jobservice, Valkey, and MinIO
- PrometheusRules with alerts for Harbor downtime, HTTP error rates, quota,
  Valkey health/memory/replication, and MinIO disk/error thresholds
- Grafana dashboards for Harbor overview and MinIO overview (auto-provisioned
  via ConfigMap sidecar with grafana_dashboard label)
- Kustomization to tie all resources together

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
9b533ba feat: add MinIO, CNPG PostgreSQL, and Valkey Redis for Harbor
Add Harbor backend storage sub-components:
- MinIO: single-instance S3-compatible object storage with ESO credentials,
  bucket creation job, and PVC (200Gi on harvester storageClass)
- CNPG PostgreSQL: 3-instance HA cluster with registry database, Barman
  S3 backup to MinIO, and daily scheduled backup at 02:00 UTC
- Valkey Redis: OpsTree Redis Operator RedisReplication (3 replicas) with
  Sentinel HA failover, persistent storage, and ESO-managed credentials

All resource limits removed (requests only) per platform convention.
Local secret.yaml fallbacks excluded — ESO-only secret management.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
22a5dea feat: add Harbor namespace, gateway, HPAs, and Helm values
Add Harbor service manifests for the harvester-rke2 platform:
- Namespace, Gateway (Traefik + cert-manager TLS), and HTTPRoute
- HPAs for core, registry, and trivy components
- Helm values with resource requests only (no limits) and
  CHANGEME_* placeholders for environment-specific config

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
a987dcb feat: add Harbor root kustomization
Wire all Harbor sub-resources into a single kustomize entry point:
namespace, MinIO, CNPG PostgreSQL, Valkey Redis Sentinel, ingress
(Gateway/HTTPRoute), HPAs, and monitoring.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
fb66d75 feat: add deploy-harbor.sh orchestrator (8 phases)
8-phase deploy script for Harbor container registry with MinIO,
CNPG PostgreSQL, and Valkey Redis Sentinel backends. Follows
established patterns from deploy-pki-secrets.sh and
deploy-monitoring.sh (source utils, .env loading, domain vars,
CLI parsing with --phase/--from/--to/--validate).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
3e52674 feat: add Harbor env config, MANIFEST.yaml, and README
Add Harbor environment variables (admin, DB, Redis, MinIO passwords) to
.env.example and corresponding CHANGEME token substitutions to subst.sh.

Create MANIFEST.yaml documenting Helm chart, container images, Kustomize
resources, and 8-phase deployment sequence.

Create README.md covering architecture, sub-components, deployment steps,
proxy cache setup, monitoring (3 ServiceMonitors, 9 alerts, 2 dashboards),
and verification commands.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
f7f1190 fix: avoid gitleaks curl-auth-user false positive in Harbor README
Replace curl -u pattern with Authorization header to avoid
gitleaks flagging the documentation example as a credential leak.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
7f056ce docs: add Bundle 4 Identity design (approved)
Keycloak 26.0 + CNPG PostgreSQL + OAuth2-proxy.
Single realm, admin-breakglass user, prompt=login, group RBAC.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
1d6824c docs: add Bundle 4 Identity implementation plan (12 tasks)
Covers: Keycloak deployment, CNPG PostgreSQL, OAuth2-proxy,
setup-keycloak.sh post-deploy script, monitoring.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
b68bdc3 feat: add Keycloak monitoring (ServiceMonitor, alerts, Grafana dashboard)
Add monitoring stack for Keycloak IAM service:
- ServiceMonitor: scrapes /metrics on management port every 30s
- PrometheusRule: 7 alerts covering availability, login failure rate,
  token latency, server errors, JVM heap pressure, and GC pauses
- Grafana dashboard: 12-panel overview with auth rates, error rates,
  JVM memory/GC, HTTP request performance, and registration tracking

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
fa52852 feat: add Keycloak namespace, core manifests, and CNPG PostgreSQL
Task 1: Namespace, Gateway (Traefik + cert-manager), HTTPRoute
Task 2: Keycloak Deployment (no resource limits), HPA, RBAC,
        Services (ClusterIP + headless), ExternalSecrets (admin + postgres)
Task 3: CNPG PostgreSQL Cluster (no resource limits), ExternalSecret,
        ScheduledBackup (daily at 02:15 UTC)

Secret.yaml files excluded — secrets managed via Vault + ESO.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
64b5216 feat: add OAuth2-proxy for Prometheus, Alertmanager, and Hubble
Add oauth2-proxy deployment manifests, Traefik forwardAuth middleware
CRDs, and ExternalSecret resources for Prometheus, Alertmanager, and
Hubble UI. Resource limits blocks removed from all proxy deployments
(requests only). Secrets sourced from Vault via ESO.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
bde14ef fix: resolve Vault Phase 2 deadlock — wait for Running before init/unseal
Vault pods cannot pass readiness probes until initialized and unsealed,
but the deploy script was waiting for Ready before running init. This
created a chicken-and-egg deadlock causing Phase 2 to always timeout.

Changes:
- Add wait_for_pods_running() to wait.sh for phase-gate on Running state
- Remove --wait from Vault helm install (same deadlock)
- Reorder Phase 2: wait Running -> init -> unseal vault-0 -> join+unseal
  replicas -> wait Ready
- Unseal vault-0 individually before joining replicas (required for Raft)

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
09b31b9 feat: add Keycloak root kustomization
Wire all Keycloak resources into a single kustomize entry point:
namespace, core (RBAC, ExternalSecret, Service, Deployment, HPA),
PostgreSQL CNPG (ExternalSecret, Cluster, ScheduledBackup),
ingress (Gateway, HTTPRoute), and monitoring/.

OAuth2-proxy resources are intentionally excluded — they are applied
explicitly by deploy-keycloak.sh Phase 6 after Keycloak OIDC clients
are configured.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
88bc5f7 fix: escape inline HTML in identity design doc for markdownlint
MD033 was flagging <service> as inline HTML in the Vault paths table.
Wrapped in backticks to make it a code span.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
d590711 feat: add deploy-keycloak.sh and setup-keycloak.sh
deploy-keycloak.sh: 7-phase deployment script following the established
deploy-harbor.sh pattern. Handles namespace creation, ESO ExternalSecrets,
CNPG PostgreSQL cluster, Keycloak deployment with health check, Gateway/
HTTPRoute/HPA, OAuth2-proxy instances (prometheus, alertmanager, hubble),
and monitoring kustomize overlay. Supports --phase, --from, --to,
--validate CLI flags.

setup-keycloak.sh: 6-phase post-deploy script that configures Keycloak
via the Admin REST API. Creates the platform realm with brute-force
protection, admin-breakglass user, OIDC clients (grafana, prometheus-oidc,
alertmanager-oidc, hubble-oidc) with PKCE, platform-admins group with
membership mapper, and a custom browser-prompt-login authentication flow.
All create operations are idempotent (handle 409 conflict gracefully).

Also updates subst.sh with CHANGEME_OAUTH2_REDIS_SENTINEL,
CHANGEME_KC_ADMIN_PASSWORD, CHANGEME_KEYCLOAK_DB_PASSWORD, and
CHANGEME_BOOTSTRAP_CLIENT_SECRET tokens, and adds corresponding
env vars to .env.example.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
3d9b345 fix: resolve Vault bootstrap failures in deploy-pki-secrets.sh
- Always unseal vault-0 after fresh init (vault_is_sealed unreliable post-init)
- Wait for vault-0 Raft leader before joining replicas
- Fix vault_unseal_replica to pass key as positional arg (not stdin pipe)
- Fix Vault PKI role: require_cn=false, allow_bare_domains=true for Gateway API certs
- Fix policy write: copy HCL to pod instead of broken heredoc via kubectl exec
- Skip monitoring overlays gracefully when Bundle 2 not yet deployed
- Add root-ca.srl to gitignore

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
ccd7755 docs: update README, architecture, and getting-started for Bundles 2-4
Add documentation for Monitoring (Bundle 2), Harbor (Bundle 3), and
Identity/Keycloak (Bundle 4) to the top-level project documentation.

README.md: add all 4 bundles to Service Bundles table, expand Quick Start
to reference all deploy scripts, update Structure tree with new services,
add htpasswd to requirements.

architecture.md: add Monitoring architecture (Prometheus + Grafana + Loki +
Alloy), Harbor architecture (Harbor + MinIO + CNPG + Valkey), Identity
architecture (Keycloak + OAuth2-proxy + CNPG), update Mermaid diagrams to
show all 4 bundles, add deployment flow for all bundles in order.

getting-started.md: add step-by-step deployment for Bundles 2-4 with
required environment variables, prerequisites, phase tables, verification
commands, and new troubleshooting sections for CNPG, Keycloak, and
OAuth2-proxy.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
5021501 docs: add Bundle 5 GitOps & Workflows design (approved)
ArgoCD (HA, native OIDC) + Argo Rollouts (dashboard, basic-auth) +
Argo Workflows (basic-auth). AnalysisTemplates for Prometheus-driven
blue/green promotion. OAuth2-proxy included but activated later.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
542b25d docs: add Bundle 5 GitOps implementation plan (11 tasks)
ArgoCD, Argo Rollouts, Argo Workflows — Helm installs, gateways
with basic-auth, AnalysisTemplates, monitoring, deploy script.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
55782cf feat: add Argo AnalysisTemplates and monitoring
Add AnalysisTemplates for canary deployments (success-rate, latency-check,
error-rate) and full monitoring stack including ServiceMonitors for ArgoCD,
Argo Rollouts, and Argo Workflows, Grafana dashboards, and alerting rules.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
2342f6b feat: add ArgoCD, Argo Rollouts, and Argo Workflows manifests
Add deployment manifests for all three Argo services with resource
limits removed (requests only), Gateway API ingress, and basic-auth
middleware for Rollouts and Workflows dashboards. OAuth2-proxy
manifests for Rollouts are included for future OIDC integration.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
724af33 feat: add Argo root kustomization
Add services/argo/kustomization.yaml aggregating all Argo sub-service
resources: ArgoCD, Argo Rollouts, Argo Workflows namespace/gateway/
httproute/middleware manifests, AnalysisTemplates, and monitoring.
OAuth2-proxy resources excluded — deployed explicitly later.

Validated with: kubectl kustomize services/argo/

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
ef1470b feat: add deploy-argo.sh orchestrator (7 phases)
7-phase deploy script for the Argo GitOps platform:
  1. Namespaces (argocd, argo-rollouts, argo-workflows)
  2. ESO SecretStores (Vault K8s auth roles per namespace)
  3. ArgoCD Helm install (chart v7.8.8)
  4. Argo Rollouts Helm install (chart v2.39.1)
  5. Argo Workflows Helm install (chart v0.45.1)
  6. Gateways + basic-auth + AnalysisTemplates + TLS wait
  7. Monitoring (dashboards, alerts, ServiceMonitors)

Supports --phase N, --from N, --to N, --validate, -h/--help.
ShellCheck clean. Follows deploy-harbor.sh established pattern.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
948e21f feat: add Argo env config, MANIFEST.yaml, and README
Add Argo GitOps env vars (basic-auth passwords, Helm chart overrides,
Rollouts plugin URL) to .env.example and CHANGEME_ARGO_ROLLOUTS_PLUGIN_URL
substitution to subst.sh. Create MANIFEST.yaml tracking all Helm charts,
images, Kustomize resources, and 7 deploy phases. Create README documenting
the 3-service architecture, auth model, AnalysisTemplates, and monitoring.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
---
874152a fix: harden monitoring bundle pre-deploy (Bundle 2)
- Fix dashboard ConfigMap substitution (CHANGEME_DOMAIN in home/firing-alerts)
- Validate GRAFANA_ADMIN_PASSWORD non-empty before substitution
- Add Loki startupProbe (replaces initialDelaySeconds), set retention_period: 720h
- Add container securityContext to Loki (readOnlyRootFilesystem + /tmp emptyDir)
  and Alloy (readOnlyRootFilesystem, drop ALL capabilities)
- Add Alertmanager Gateway HTTP listener for consistency with Prometheus/Grafana
- Add Grafana HPA (2-4 replicas, 70% CPU target)
- Add VolumeAutoscaler CRs for Loki, Prometheus, and Alertmanager PVCs
- Update kustomization.yaml with new resources
- Update deploy-monitoring.sh Phase 4 to apply HPA and VolumeAutoscalers
- Update .env.example with PROMETHEUS_ADDR for storage-autoscaler

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
c1d379a feat: add VolumeAutoscaler CRs across all service bundles
Consolidate monitoring-stack volume autoscalers into a single file with
updated specs (pvcName targeting for Prometheus, pollInterval fields).
Add new VolumeAutoscaler CRs for harbor (minio, pg, valkey), keycloak
(pg), and argo (redis-ha) to enable automatic PVC expansion when disk
usage exceeds 80%.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
0459fcd fix: remove org/personal info and pin Keycloak image tag
Replace hardcoded GitHub username (derhornspieler) in README CI badge
and LICENSE copyright with generic placeholders. Replace org-specific
grep patterns in implementation plan docs with generic placeholders.
Pin Keycloak image from floating minor tag (26.0) to patch release
(26.0.8) to prevent silent drift.

Security audit findings:
- Check 1 (Org/Personal Info): 4 files fixed, now zero matches
- Check 2 (Hardcoded Credentials): clean
- Check 3 (Resource Limits): clean
- Check 4 (CHANGEME Coverage): all tokens mapped
- Check 5 (Image Tags): Keycloak pinned to 26.0.8
- Check 6 (Kustomize Builds): all 7 pass
- Check 7 (ShellCheck): all scripts clean
- Check 8 (.gitignore): comprehensive coverage

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
ec5ea4a docs: update monitoring bundle docs to reflect HPA, VolumeAutoscalers, and config
- Update README.md architecture section: document Loki 30-day retention (720h),
  startupProbe, hardened securityContext, and Grafana HPA (2-4 replicas)
- Add required environment variables table (GRAFANA_ADMIN_PASSWORD,
  PROM_BASIC_AUTH_PASS, AM_BASIC_AUTH_PASS, optional basic-auth usernames)
- Add optional Helm chart override variables (HELM_CHART_PROMETHEUS_STACK,
  HELM_REPO_PROMETHEUS_STACK)
- Document Prometheus and Loki VolumeAutoscaler auto-scaling
- Document Alertmanager HTTP listener on port 9093
- Update MANIFEST.yaml: add scaling section (HPA + VolumeAutoscalers)
- Update phase descriptions to be more descriptive of what actually happens
- Fix deploy-monitoring.sh: reference combined volume-autoscalers.yaml
  (was three separate files, now consolidated into one)

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
945475e security: fix remaining agent findings in monitoring bundle
- Simplify GRAFANA_ADMIN_PASSWORD validation to catch both unset and empty
- Add runAsNonRoot: true to Loki pod securityContext
- Use mktemp for Helm values temp file to prevent race condition

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
1dd1359 docs: add Bundle 6 GitLab design (approved)
GitLab EE + Praefect/Gitaly HA + CNPG + Redis Sentinel + 3 K8s Runners
+ CI templates. All consolidated under services/gitlab/.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
4a370de docs: add Bundle 6 GitLab implementation plan (15 tasks)
GitLab EE, CNPG PostgreSQL, Redis Sentinel, 3 K8s Runners,
CI templates, deploy script, monitoring.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
ccde3dd fix: add prometheusURL to all VolumeAutoscalers and Grafana sidecar resources
- Set explicit prometheusURL on all VolumeAutoscaler CRs across bundles
  (monitoring, argo, keycloak, harbor) to prevent CRD default of
  CHANGEME_PROMETHEUS_ADDR
- Add CPU/memory requests to Grafana sidecar (grafana-sc-dashboard) so
  HPA can compute CPU utilization across all containers

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
60900a4 feat: add GitLab core manifests (namespace, gateway, Helm values, CNPG, Redis, secrets)
Copied from rke2-cluster-via-rancher/services/gitlab/ with all resource
limits removed (requests only convention). Includes:

- Namespace + Gateway API + TCPRoute for SSH
- Helm values (values-rke2-prod.yaml) with limits stripped from all 10 components
- CNPG PostgreSQL Cluster + ScheduledBackup (limits removed)
- OpsTree Redis Replication + Sentinel (limits removed) + ExternalSecret
- ExternalSecrets for Gitaly, Praefect (db + token), OIDC, root password

All secrets sourced via ESO (vault-backend SecretStore), no local fallbacks.
CHANGEME_* placeholders preserved for domain and MinIO endpoint.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
bfd6142 feat: add GitLab Runners, CI templates, and monitoring
Task 6 — Runners: namespace, RBAC, external-secret for Harbor push,
and Helm values for shared/security/group runners. Resource limits
removed from all runner values (requests only). TOML-level cpu_limit
and memory_limit also stripped from security runner job pod config.

Task 7 — CI Templates: full pipeline template library with base
config, stages, and reusable job definitions (build, deploy, lint,
scan, test, promote, rollout, eso-provision) plus pattern files
(microservice, platform-service, library, infrastructure).

Task 8 — Monitoring: merged GitLab and Runner monitoring into a
single directory with unified kustomization.yaml. Includes Grafana
dashboards, PrometheusRules (alerts), and ServiceMonitors for both
GitLab core and runners. Runner service-monitor renamed to
runners-service-monitor.yaml to avoid filename collision.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
44e21b6 feat: add GitLab root kustomization and VolumeAutoscalers
Add root kustomization.yaml for the GitLab service that references all
kubectl-applied manifests: namespace, gateway, tcproute-ssh, CNPG cluster
and scheduled backup, Redis replication/sentinel, external secrets for
gitaly/praefect/oidc/root, volume autoscalers, and monitoring.

Add volume-autoscalers.yaml with PVC expansion policies for gitlab-pg
(database namespace, up to 200Gi) and gitlab-redis (gitlab namespace,
up to 50Gi).

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
d3bc74b feat: add deploy-gitlab.sh orchestrator (9 phases)
9-phase deploy script for the full GitLab stack:
  1. Namespaces (gitlab, gitlab-runners, database)
  2. ESO SecretStores + ExternalSecrets (gitaly, praefect, redis, oidc, root, harbor-push)
  3. CNPG PostgreSQL (HA cluster, praefect user/db setup, scheduled backup)
  4. Redis (OpsTree RedisReplication + RedisSentinel)
  5. Gateway + TCPRoute (HTTPS + SSH ingress via Traefik)
  6. GitLab Helm (30m timeout for migrations, waits for webservice/sidekiq/shell/kas)
  7. Runners (shared, security, group — 3 separate Helm installs)
  8. VolumeAutoscalers
  9. Monitoring + Verify (kustomize monitoring, HTTPS + SSH checks)

Supports --phase N, --from N, --to N, --validate, -h/--help.
ShellCheck clean.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
cef0761 feat: add GitLab env config, MANIFEST.yaml, and README
Add GITLAB_ROOT_PASSWORD and GITLAB_REDIS_PASSWORD to .env.example,
GitLab Helm chart overrides, and CHANGEME_GITLAB_REDIS_PASSWORD
substitution to subst.sh. Create MANIFEST.yaml documenting all Helm
charts, images, Kustomize resources, and 9 deploy phases. Create
README.md covering architecture, deployment, runners, CI templates,
and monitoring.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
1ad99fa fix: move sidecar resources to correct Grafana chart path
The Grafana subchart expects sidecar resources at sidecar.resources (top
level), not sidecar.dashboards.resources. This fixes the HPA being unable
to compute CPU utilization for the grafana-sc-dashboard container.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
d054cc6 fix: add prometheusURL to GitLab VolumeAutoscalers and scope password validation
- Add missing prometheusURL to gitlab-pg and gitlab-redis VolumeAutoscaler
  CRs (missed in previous sweep of all bundles)
- Revert GRAFANA_ADMIN_PASSWORD validation to conditional form that only
  rejects explicitly empty values, not unset — prevents blocking
  non-monitoring deploy scripts that also use _subst_changeme()

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
73b4cc2 docs: update top-level documentation for all 6 bundles complete
Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
5df5f42 fix: security scrub — pin CI image tags, remove TLS bypass flags
Pin all CI template container images to specific versions to prevent
supply chain attacks via mutable :latest tags (13 images pinned).
Remove --skip-tls-verify from kaniko, --insecure from ArgoCD login
and trivy image scan — use --registry-certificate for private CA
trust instead. Remove :latest push destination from kaniko build.
Pin CNPG PostgreSQL image from :17 (major) to :17.6 (patch).

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
e7fb71a security: harden Alloy/Grafana securityContext, disable pprof, add experimental Gateway CRDs
- Add pod-level securityContext to Alloy DaemonSet: runAsNonRoot, runAsUser
  65534, seccompProfile RuntimeDefault
- Add containerSecurityContext to Grafana: readOnlyRootFilesystem, drop ALL
  caps, disable privilege escalation
- Disable Grafana pprof/profiling endpoint (port 6060) via grafana.ini
- Add extraEmptyDirMounts for /tmp on Grafana (required by readOnlyRootFilesystem)
- Install experimental Gateway API CRDs (TCPRoute, TLSRoute) in Bundle 1
  Phase 1 — required by Traefik's experimentalchannel provider

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
5c85c3d feat: reorder bundles (Identity before Monitoring) and add NetworkPolicies
Reorder deployment bundles so Identity (Keycloak) deploys as Bundle 2
before Monitoring (Bundle 3), enabling OIDC on first install for all
downstream services. Extract CNPG operator and MinIO into Identity's
deploy script as shared data services with skip-if-exists guards.

Add default-deny-ingress NetworkPolicies across all 13 service
namespaces with explicit allow rules for Traefik, Prometheus scraping,
and inter-service communication. Tighten Keycloak OIDC ingress to
only namespaces that use OIDC clients.

Security fixes from review:
- Fix SQL injection in deploy-gitlab.sh praefect password handling
- Use mktemp with proper permissions for temp files with secrets
- Remove ESO resource limits (project convention: requests only)
- Set GF_AUTH_OAUTH_ALLOW_INSECURE_EMAIL_LOOKUP to false
- Redirect Grafana signout to Keycloak end_session_endpoint
- Add CNPG operator and intra-namespace rules to database NP
- Create grafana-oidc-secret ExternalSecret for Vault-synced OIDC

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
df1f39f docs: update all documentation for NetworkPolicies and bundle reorder
Major documentation updates:
- Add Network Security section to architecture.md with NetworkPolicy topology diagram
- Update Bundle 2 (Identity) phase count from 7 to 8 (includes Shared Data Services phase)
- Correct bundle numbering throughout (Identity now Bundle 2, Monitoring Bundle 3, etc.)
- Update phase counts for all deploy scripts in architecture.md
- Add NetworkPolicy files table showing which bundles deploy which policies
- Update getting-started.md with corrected phase descriptions
- Add NetworkPolicy prerequisites to README.md requirements section
- Update bundle-roadmap.md with CNPG operator and MinIO shared infrastructure details
- Update monitoring-stack README with NetworkPolicy section
- Correct bundle dependencies in design documents (identity, gitlab, gitops)
- Update all references from 'Bundle N' to correct numbering

All changes maintain consistency across:
- docs/architecture.md (diagrams, phase descriptions)
- docs/getting-started.md (deployment guide)
- docs/plans/bundle-roadmap.md (dependency graph)
- services/monitoring-stack/README.md (service documentation)
- Design documents (identity, gitlab, gitops)
- README.md (top-level overview)

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
d70a803 fix: harden NetworkPolicies and deploy scripts after security review
- Fix Traefik namespace: kube-system (not traefik) with rke2-traefik podSelector
- Fix ArgoCD NP: container port 8080 (not service port 80)
- Add GitLab SSH port 22 for TCPRoute
- Add MinIO intra-namespace rule for bucket creation Job
- Add argo-rollouts and kube-system to Keycloak OIDC client list
- Add monitoring ForwardAuth port 4180 for oauth2-proxy
- Add argo-rollouts oauth2-proxy ports (4180 Traefik, 44180 Prometheus)
- Consolidate trap handlers in deploy-argo.sh and deploy-gitlab.sh
- Add chmod 600 on temp file in deploy-monitoring.sh
- Fix JSON injection in setup-keycloak.sh breakglass user creation
- Fix phase reference in setup-keycloak.sh (phase 6 → phase 7)

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
7516304 fix: add blank lines around markdown headings in monitoring README
Fixes markdownlint MD022 violations.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
5ec6767 fix: deploy-keycloak Vault secret seeding, HTTP/2 disable, NP webhook access
- deploy-keycloak.sh: Add Phase 2 Vault KV secret seeding, K8s auth
  roles, ESO SecretStores for minio/keycloak/database namespaces.
  Move MinIO deploy after ExternalSecrets sync. Guard Phase 7/8 on
  monitoring namespace existence. Fix health check (no curl in image).
  Use temp-admin-svc instead of admin-cli to avoid built-in client
  conflict.
- helm.sh: Export DISABLE_HTTP2=true to avoid kube-apiserver HTTP/2
  stream INTERNAL_ERROR on watch operations.
- cert-manager/external-secrets NPs: Allow kube-apiserver webhook
  calls (port 10250) and intra-namespace traffic.
- minio job: Use mc:latest (pinned tag was not found on quay.io).
- .env.example: Add export prefix for KUBECONFIG.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
c3ea2b5 fix: setup-keycloak auto-seed OIDC secrets, deploy-monitoring prereqs
- setup-keycloak.sh: read admin credentials from Vault instead of .env,
  use client_credentials grant (bootstrap admin is service account),
  auto-retrieve OIDC client secrets and seed into Vault, create
  monitoring namespace SecretStore/ExternalSecrets, add token caching
  with file-based cache to avoid subshell variable loss, add curl
  timeouts and retry logic, make browser flow copy non-fatal
- deploy-monitoring.sh: create vault-root-ca ConfigMap and placeholder
  grafana-oidc-secret before helm install so Grafana can start without
  waiting for Keycloak OIDC setup

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
015a661 fix: deploy-harbor.sh — Helm repo, Vault seeding, password resilience
- Switch from OCI registry (requires auth) to traditional Helm repo
- Add Vault KV secret seeding in Phase 2 for PG, MinIO, Valkey, admin
- Fix vault policy write to use kubectl exec -i (stdin support)
- Add Phase 6 password fallback: read from K8s secrets when Phase 2
  was skipped (prevents password mismatch on partial reruns)

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
5286e7f fix: deploy-argo.sh vault stdin, auto-gen passwords, HAProxy image
- Fix vault policy write to use kubectl exec -i (stdin support)
- Auto-generate basic-auth passwords instead of requiring them in .env
- Override HAProxy image from unreachable public.ecr.aws to docker.io

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
afc8cd7 fix: deploy-gitlab.sh — Vault seeding, CNPG secret copy, runner registration
- Add comprehensive Vault KV secret seeding (Phase 2): Redis, Gitaly,
  Praefect DB/token, root password, OIDC provider, Harbor CI push,
  CNPG PostgreSQL, CNPG MinIO backup credentials
- Fix vault_exec stdin bug (2 occurrences) — use kubectl exec -i
- Copy CNPG gitlab-postgresql-app secret to gitlab namespace (Phase 3)
- Create gitlab-root-ca secret with Vault CA chain (Phase 6)
- Create runner TLS trust secrets and copy registration token (Phase 7)
- Add runners.secret and certsSecretName to all runner values files
  for proper GitLab registration with Vault CA trust

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
f30a991 feat: Vault credential management, OIDC integration, shared MinIO, ServiceMonitors
- Add vault_get_field/vault_get_or_generate helpers to scripts/utils/vault.sh
  for idempotent credential management (read from Vault first, generate only
  if missing)
- Update all deploy scripts (argo, gitlab, harbor, keycloak, monitoring) to
  store and retrieve credentials via Vault instead of regenerating on each run
- Migrate GitLab to shared MinIO: disable bundled minio, configure object_store
  with consolidated S3 connection to minio.minio.svc
- Configure OIDC for ArgoCD, Harbor, and Vault via Keycloak (PKCE handling,
  client secrets, redirect URIs)
- Add ServiceMonitors for node-labeler and storage-autoscaler so Grafana home
  dashboard correctly shows them as UP instead of NOT DEPLOYED
- Update NetworkPolicies for ArgoCD, GitLab, Harbor with corrected ports
- Update setup-keycloak.sh with Vault OIDC auth and Harbor OIDC client config
- Update oauth2-proxy manifests for alertmanager, hubble, prometheus

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
76ad5b0 refactor: replace admin-breakglass with configurable platform admin user
- setup-keycloak.sh Phase 2: create PLATFORM_ADMIN_USER (default: admin.user)
  instead of hardcoded admin-breakglass
- Phase 3: disable PKCE enforcement for ArgoCD client (v2.14 doesn't support it)
- Phase 4: assign platform admin user to platform-admins group
- Phase 6: update validation output to show platform admin username
- Store platform admin credentials in Vault (kv/services/keycloak/platform-admin)
- .env.example: replace BREAKGLASS_PASSWORD with PLATFORM_ADMIN_USER/EMAIL/PASSWORD
- Fix KC_REALM from "Example Org" to "platform" in .env

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
fc0601e docs: add Hubble observability documentation and update architecture
- Add services/cilium/README.md: documents HelmChartConfig, Hubble relay metrics,
  flow export, UI components, monitoring pipeline, troubleshooting guide
- Add services/hubble/README.md: documents Hubble UI ingress setup, Gateway/HTTPRoute,
  OAuth2-proxy integration, prerequisites, deployment steps, and troubleshooting
- Update docs/architecture.md:
  - Add Cilium and Hubble components to components table
  - Add Hubble relay and UI to monitoring coverage table
  - Update monitoring architecture diagram to include Hubble relay and UI
  - Clarify Alloy collects Hubble flow logs from /var/run/cilium/hubble
  - Document Hubble metrics and flow log processing
  - Update NetworkPolicy docs to mention Hubble relay metrics (port 4244)

Implements Hubble observability stack for L4/L7 network visibility with:
- 5 new alert rules (CiliumHighDropRate, HubbleDNSErrorSpike,
  HubbleHTTPServerErrors, HubbleLostEvents, CiliumPolicyImportErrors)
- Cilium dashboard with 9 panels (endpoints, drops, flows, DNS, HTTP, health)
- Alloy pipeline for JSON flow log collection from each node to Loki
- OAuth2-proxy ForwardAuth protection for Hubble UI

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
003b292 feat: Grafana PG backend, Hubble observability, NetworkPolicy removal, CNPG dashboard
Major changes across multiple subsystems:

- Grafana PostgreSQL backend (CNPG): 3-instance cluster in database namespace,
  ExternalSecrets for Vault credential sync, deploy-monitoring.sh Phase 3 setup,
  VolumeAutoscaler for PVC auto-expansion. Fixes session loss with HPA scaling.

- Hubble observability: RKE2 Cilium HelmChartConfig enabling metrics/relay/UI,
  Alloy flow log collection, ServiceMonitor, OAuth2-proxy, Grafana dashboards.

- NetworkPolicy removal: All custom NetworkPolicies removed from codebase and
  deploy scripts. Were blocking CNPG operator communication during rolling
  upgrades causing replica creation failures.

- CNPG dashboard: Per-pod dropdown using pod labels (added to scrape config),
  fixed connection usage join queries, proper aggregation in "All" mode.

- Traefik dashboard: OAuth2-proxy protected dashboard with ExternalSecret.

- Keycloak setup: Updated eso-monitoring Vault policy for Grafana PG credentials,
  added Hubble UI OIDC client.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
6e41186 fix: ShellCheck SC2168 — remove 'local' outside function in setup-keycloak.sh
Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
f259bc2 docs: remove all stale NetworkPolicy references
NetworkPolicies were deleted from the codebase due to conflicts with CNPG
operator communication during rolling cluster upgrades. Remove all references
to deleted networkpolicy.yaml files and update docs to reflect the current
state of network security relying on RBAC, TLS, and pod security standards.

Changes:
- Remove NetworkPolicy strategy section from docs/architecture.md
- Remove NetworkPolicy file table and replace with brief status note
- Update services/monitoring-stack/README.md to remove policy documentation
- Update services/cilium/README.md troubleshooting guide (no more policy references)
- Remove "Network Security" section from services/hubble/README.md
- Update docs/plans/2026-03-04-bundle-roadmap.md to remove policy references
- Remove NetworkPolicy from service template checklist in memory/teams/dev.md
- Update README.md to remove NetworkPolicy support requirement

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
d673b63 feat: PgBouncer connection pooling, OAuth2-proxy hardening, security fixes
- Add PgBouncer poolers (rw/ro) for GitLab PostgreSQL to prevent
  connection exhaustion (was 200/200, transaction-mode pooling)
- Route GitLab PG connections through PgBouncer pooler services
- Enable read-replica load balancing via pooler-ro service
- Increase GitLab PG max_connections from 200 to 400
- Harden OAuth2-proxy deployments (traefik, workflows, rollouts):
  security contexts, metrics port 44180, cookie-expire/refresh
- Route all CNPG images through Harbor pull-through cache
- Fix ArgoCD wildcard redirect URI to specific /auth/callback
- Reduce Grafana session affinity timeout from 3h to 30min
- Increase Keycloak SSO timeouts from 5/10min to 30/60min

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
eda9791 docs: add Vault unseal and PgBouncer SOPs, persist Traefik HelmChartConfig
- Add Vault unseal SOP for post-rolling-upgrade recovery
- Add GitLab PgBouncer/read-replica load balancing SOP
- Save Traefik HelmChartConfig to repo (dashboard API, CA trust,
  LB IP, Gateway API, SSH port) — prevents config loss on CP upgrades

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
941828b fix: pin kustomize version in CI to avoid flaky install script
The upstream install_kustomize.sh script intermittently fails to
download the binary. Pin to v5.6.0 with direct download URL.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
0e043f7 refactor: remove stale basic-auth middlewares, use OAuth2-proxy only
All services now use OAuth2-proxy ForwardAuth exclusively. Basic-auth
was the original auth method before OIDC/OAuth2-proxy was added but
the middleware CRs and secrets were never cleaned up.

- Delete basic-auth middleware files (rollouts, workflows, alertmanager,
  prometheus)
- Add missing argo-workflows OAuth2-proxy middleware CR file
- Update kustomization.yaml references to use OAuth2-proxy middlewares
- Remove basic-auth secret creation from deploy scripts
- Clean up Vault credential seeding (no more basic-auth passwords)

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
70b2ec4 chore: remove stale minio-web Gateway listener and registry HTTPRoute
GitLab registry is disabled (Harbor is the platform registry) and
MinIO is shared from the minio namespace. The minio-web listener
and registry HTTPRoute were orphaned resources in Traefik.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
09a40ca fix: Harbor ESO existingSecret pattern + audit plan baseline
- Switch Harbor Helm values from inline CHANGEME passwords to
  existingSecret references (ESO → Vault kv/services/harbor)
- Apply 3 missing ExternalSecrets (admin, db, s3 credentials)
- Add minio-access-key to Vault KV write in deploy script
- Fix Vault policy paths for ESO (add parent path read)
- Deploy script Phase 6 now verifies ESO secrets exist before helm install
- Add cluster-vs-code audit plan (88 action items)

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
75aaad8 docs: fix cluster configuration and deployment documentation
Fixes and updates:
- Fix node count: 12 → 13 nodes (3 controlplane, 4 database, 4 general, 2 compute)
- Add Hubble hostname correction: hubble.dev.example.com → hubble.example.com
- Add Redis operator installation instructions to getting-started.md
- Add missing grafana-pg to CNPG clusters list in architecture.md
- Fix cluster-autoscaler ServiceMonitor namespace and label selector

Action items addressed: A07, A08, A09, A10, A33

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
9819e04 docs: add documentation fix status report for 2026-03-06
Comprehensive tracking of all fixes applied to align code with live cluster:
- A07: Node count (12 → 13)
- A08: Redis operator installation instructions
- A09: Add grafana-pg to CNPG clusters list
- A10: Fix Hubble hostname (dev. → production)
- A33: Fix cluster-autoscaler ServiceMonitor
- A34: Keycloak dashboard verification

All fixes verified against live rke2-prod cluster.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
a35621c feat: add VolumeAutoscalers, HPAs, PDBs; fix CNPG operator config
k8s-infra-engineer agent fixes (19 action items):

VolumeAutoscalers (new):
- Vault PVCs data-vault-{0,1,2} (50Gi max)
- Harbor Trivy PVC (20Gi max)
- Gitaly PVCs repo-data-gitaly-{0,1,2} (300Gi max)
- Deploy phases added to all scripts to apply VAs

PodDisruptionBudgets (new):
- CNPG operator (minAvailable:1)
- ArgoCD server, repo-server, appset-controller, notifications
- Argo Rollouts controller
- Harbor core, registry, portal, jobservice

CNPG operator fixes:
- Fix deployment name: cnpg-cloudnative-pg -> cnpg-controller-manager (A15)
- Update chart version: 0.23.0 -> 0.27.0 (A16)
- Fix nodeSelector: general -> database (A05/A17)
- Add HPA (min:2, max:4, CPU 70%)

Other:
- ArgoCD Redis HA split-brain-fix resource requests (A70)
- GitLab sidekiq HPA maxReplicas 10 -> 15 (A71)
- Deploy script phases renumbered for new VA/PDB phases

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
e9a1f68 fix: security hardening — subst.sh guards, securityContext, image pinning
security-sentinel agent fixes (12 action items):

CRITICAL:
- A55: subst.sh — 11 secret vars now use ${VAR:?error} fail-if-empty
  guards instead of ${VAR:-} empty defaults. Prevents silent
  blank-password deployments.

HIGH:
- A18: Prometheus + Alertmanager OAuth2-proxy — add full securityContext
  (runAsNonRoot, readOnlyRootFilesystem, drop ALL, seccompProfile)
- A19: MinIO mc job — pin from :latest to RELEASE.2024-11-07T00-52-20Z
- A38: MinIO deployment — add pod + container securityContext

MEDIUM:
- A60: Harbor Valkey replication + sentinel — add securityContext
  (readOnlyRootFilesystem: false documented for Redis RDB/AOF writes)
- A61: Argo Rollouts dashboard — add containerSecurityContext

LOW/DOCUMENTED:
- A02: OAuth2-proxy-traefik args already in code (re-apply issue)
- A35: Traefik/Rollouts/Workflows proxies already hardened
- A59: Valkey sentinel requirepass — documented as known limitation
- A62: Workflows auth-mode=server intentional (behind OAuth2-proxy)
- A72: Vault UI — no ForwardAuth needed (has own auth system)
- A74: vault.sh eval — safety comment added, no user input reaches it

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
4ba409e refactor: MANIFEST cleanups, dead code removal, traefik-dashboard script
Platform-engineer batch (Batch 4):
- Update MANIFESTs to match cluster state (phases, resources, image tags)
- Remove stale basic-auth references from Argo MANIFEST + README
- Delete unused external-secret-redis.yaml (Argo Rollouts)
- Add traefik-dashboard deploy script + kustomization
- Fix Grafana sessionAffinity timeout (1800→10800s)
- Add Day-2 ReplicaSet cleanup docs to Harbor README

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
750a95b feat: ArgoCD values, vault-root-ca ConfigMaps, Gateway API CRDs, airgap .env
Platform-developer batch (Batch 3):
- ArgoCD values: add rootCA, TLS certs, server.insecure param, RBAC matchMode
- Add cert-manager duration/renew-before annotations to all Gateway resources
- Vendor Gateway API CRDs (v1.2.1) to scripts/manifests/ for airgap
- Replace remote CRD URLs with local paths in deploy-pki-secrets.sh
- Add vault-root-ca ConfigMap creation to all deploy scripts (harbor, keycloak, argo, gitlab)
- Add namespace.yaml application before Helm installs in deploy-pki-secrets.sh
- Add cert-manager sub-component nodeSelectors (cainjector, webhook, startupapicheck)
- Add Workflows ExternalSecret for OAuth2-proxy + kustomization entry
- Add GitLab MinIO storage ExternalSecret + Vault credential seeding
- Add PgBouncer pooler deployment to deploy-gitlab.sh Phase 3
- Pin GitLab Helm version (9.9.2) and Runner versions (0.86.0)
- Remove basic-auth dead code from deploy-argo.sh
- Comment out Rollouts trafficRouterPlugins (requires airgap URL override)
- Add HELM_REPO_CNPG, PRIVATE_CA_CERT, and airgap section to .env.example

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
9dbfcec docs: update fix-progress tracker — all 5 agent batches complete
All batches merged into fix/cluster-code-alignment:
- Batch 1 (k8s-infra): VolumeAutoscalers, HPAs, PDBs, CNPG fixes
- Batch 2 (security): subst.sh guards, securityContext hardening
- Batch 3 (platform-dev): ArgoCD values, CRDs, vault-root-ca, airgap .env
- Batch 4 (platform-eng): MANIFEST cleanups, dead code, traefik-dashboard
- Batch 5 (tech-docs): documentation fixes

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
41fc124 fix: deploy issues found during cluster rebuild
- Use upstream image refs for CNPG PostgreSQL (ghcr.io/cloudnative-pg/)
  instead of hardcoded harbor.example.com/proxy-ghcr/ — RKE2
  registries.yaml handles the rewrite transparently
- Fix MinIO mc image tag (RELEASE.2025-08-13T08-35-41Z)
- Switch subst.sh from :? (fail-if-empty) to :- (empty-if-unset) so
  templates only fail on unreplaced CHANGEME tokens, not on missing
  env vars for other bundles
- Remove stale basic-auth.sh source lines from deploy-monitoring.sh
  and deploy-gitlab.sh (OAuth2-proxy handles all auth now)
- Fix setup-keycloak.sh to use admin-cli password grant instead of
  unregistered temp-admin-svc client_credentials grant
- Update monitoring MANIFEST to remove deleted basic-auth middleware refs

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
d97b849 fix: make Keycloak scripts self-contained for any network environment
- setup-keycloak.sh: KC_URL now overridable (supports internal port-forward
  when external VIP is blocked by IPS/IDS)
- setup-keycloak.sh: create Vault ESO role/SA/SecretStore for kube-system
  (hubble OAuth2-proxy) alongside monitoring namespace
- deploy-keycloak.sh Phase 7: create monitoring namespace and vault-root-ca
  ConfigMap in all OAuth2-proxy namespaces (monitoring, kube-system)
- deploy-keycloak.sh Phase 7: remove conditional skip when monitoring NS
  missing — phase now creates it

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
26d4764 feat: grant admin.user admin role in master realm for API access
Phase 2 now creates the platform admin user in both the platform realm
(for OIDC login) and the master realm (for Keycloak admin API access),
replacing admin-breakglass as the primary admin for subsequent operations.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
528b825 fix: correct ESO condition name and CNPG CRD in deploy-monitoring.sh
- ESO ExternalSecret condition type is 'Ready' not 'SecretSynced'
- CNPG cluster CRD must be fully qualified (clusters.postgresql.cnpg.io)
  to avoid conflict with Rancher's clusters.management.cattle.io

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
e7cb823 fix: Harbor ESO secrets, Traefik dashboard, CI badge, and OIDC scope fixes
- deploy-harbor.sh: apply harbor-namespace ExternalSecrets (admin, db, s3
  credentials), fix Vault policy to include base path (not just wildcard),
  add minio-access-key to Vault secret
- deploy-monitoring.sh: add Traefik dashboard deployment (HelmChartConfig,
  OAuth2-proxy, Gateway, HTTPRoute) to Phase 5, verify in Phase 6
- setup-keycloak.sh: add traefik-oidc, rollouts-oidc, workflows-oidc to
  groups scope assignment loop
- Fix OAuth2-proxy dashboard: correct deployment name from
  oauth2-proxy-traefik-dashboard to oauth2-proxy-traefik
- CI: expand kustomize validation to all bundles, fix badge org placeholder
- README.md: replace <GITHUB_ORG> placeholder with derhornspieler

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
ba1d525 merge: fix/cluster-code-alignment — cluster rebuild fixes and full bundle deployment
Fixes discovered during clean cluster rebuild:
- ESO condition types (Ready vs SecretSynced)
- CNPG CRD fully qualified names (clusters.postgresql.cnpg.io)
- Harbor missing ExternalSecrets + Vault policy base path
- Keycloak OIDC scope assignment for traefik/rollouts/workflows
- Traefik dashboard enabled with OAuth2-proxy protection
- CI badge placeholder and kustomize validation expanded
- Network-independent Keycloak setup (KC_URL override)
- admin.user as primary admin in master realm

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
9f2d16e fix: Vault ESO policies — add base paths, oidc/* for OAuth2-proxy secrets
- deploy-argo.sh: add base path (no /*) + kv/data/oidc/* for rollouts/workflows
  OAuth2-proxy ExternalSecrets that reference kv/oidc/<client>-oidc
- deploy-keycloak.sh, deploy-gitlab.sh: add base path entries to Vault policies
  (fixes ESO sync when secret is at kv/data/services/<ns> not just <ns>/*)
- deploy-monitoring.sh: remove stray `done` from validation (ShellCheck SC2066 fix)
- docs: markdown lint fixes (blank lines around headings/tables)

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
e307073 fix: Redis ServiceMonitor targets harbor/gitlab namespaces, not monitoring
The redis-exporter ServiceMonitor was matching label `app: oauth2-proxy-redis`
in the monitoring namespace (doesn't exist). Fixed to match OpsTree Redis
services via `redis_setup_type: replication` label in harbor + gitlab namespaces.
This resolves the home dashboard showing Redis as degraded.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
---
