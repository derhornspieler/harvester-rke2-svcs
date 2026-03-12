# Service Ownership Model — Design Specification

**Date**: 2026-03-11
**Status**: Approved
**Authors**: rocky, Claude Opus 4.6

## Executive Summary

Refactor the Fleet GitOps deployment architecture so each service owns ALL its
external dependencies. Replace three monolithic init Jobs (vault-init,
keycloak-config, minio-init) with a minimal bootstrap layer and per-service
init Jobs. Add a MinimalCD developer experience layer using ArgoCD
ApplicationSets for application deployments on top of Fleet-managed platform
infrastructure.

## Problem Statement

The current architecture has three centralized init Jobs that create external
dependencies for all services:

- `vault-init` creates ALL Vault policies, ESO roles, and namespace SecretStores
- `keycloak-config` creates ALL 14 OIDC clients in a single Job
- `minio-init` creates ALL MinIO buckets and access keys

This creates a 16-bundle bottleneck at `identity-keycloak-config` — every
service in bundles 20-50 must wait for all 14 OIDC clients to be created before
deploying. Adding a new service requires modifying multiple centralized Jobs
rather than self-contained service manifests.

## Architecture

### Three-Layer Model

```
Layer 0: Foundational Infrastructure (centralized, runs once)
  vault-init (minimal)    -> PKI engines, KV v2, K8s auth, bootstrap roles
  keycloak-realm-init     -> Platform realm, SSO config,
                             5 OIDC clients: Vault, Rancher, Traefik, Hubble, Keycloak

Layer 1: Per-Service Init Jobs (one per service, ephemeral)
  <service>-init Job      -> Vault policy + ESO auth roles
                          -> Keycloak OIDC client (if user-facing)
                          -> MinIO bucket + access key (if uses object storage)
                          -> Generate passwords (admin, Redis, DB, etc.)
                          -> Push all credentials to Vault KV
                          -> Self-destructs via ttlSecondsAfterFinished: 120 (2 minutes)

Layer 2: Declarative Manifests (Fleet-managed, standard bundles)
  CNPG Cluster CRs        -> Reference credentials from Layer 1
  Redis/Valkey CRs         -> Reference credentials from Layer 1
  Helm charts              -> Reference ExternalSecrets from Layer 1
  Gateway + HTTPRoute      -> TLS auto-provisioned via cert-manager shim
  HPA, VolumeAutoscaler    -> Per-service scaling
  ESO ExternalSecrets      -> Read from Vault paths created by Layer 1
```

### Credential Flow

```
Init Job generates password
  -> writes to Vault KV (kv/services/<service>/*)
     -> ESO PushSecret (updatePolicy: Replace) handles rotation
        -> ExternalSecret reads from Vault
           -> K8s Secret consumed by service Pod
```

### Rotation

ESO PushSecret with `updatePolicy: Replace` handles ongoing credential
rotation. The init Job is only for bootstrap. Service Pods never have write
access to Vault — only ESO controllers do via the `eso-writer` role.

### Security Model

**Vault roles per namespace** (scoped by dependency type):

| Role | Used By | Vault Permissions | Lifecycle |
|------|---------|-------------------|-----------|
| bootstrap-keycloak-&lt;ns&gt; | Init Jobs needing OIDC | Read kv/admin/keycloak, write kv/services/&lt;ns&gt;/*, bind pre-created policies | Ephemeral (Job TTL 1h) |
| bootstrap-minio-&lt;ns&gt; | Init Jobs needing S3 | Read kv/admin/minio, write kv/services/&lt;ns&gt;/*, bind pre-created policies | Ephemeral (Job TTL 1h) |
| bootstrap-base-&lt;ns&gt; | Init Jobs (Vault-only) | Write kv/services/&lt;ns&gt;/*, bind pre-created policies | Ephemeral (Job TTL 1h) |
| eso-writer-&lt;ns&gt; | ESO PushSecret controller | Write to kv/services/&lt;ns&gt;/* | Persistent (for rotation) |
| eso-reader-&lt;ns&gt; | ESO ExternalSecret controller | Read from kv/services/&lt;ns&gt;/* | Persistent |

**Key security constraints:**
- Init Jobs authenticate to Vault via **K8s auth** (`vault write auth/kubernetes/login`),
  NEVER via root token. The root token is a human-only breakglass event.
- Admin credential reads are scoped per dependency type — a monitoring init Job
  cannot read MinIO root credentials, only Keycloak admin creds.
- Init Jobs **cannot create** arbitrary Vault policies. vault-init pre-creates
  template policies (`eso-reader-<ns>`, `eso-writer-<ns>`). Init Jobs can only
  **bind** existing policies to auth roles.
- **Job TTL**: Currently 120 seconds (2 minutes, as of 2026-03-12) to prevent completed Jobs from hoarding CPU requests.
  This design doc proposed 3600 (1 hour) as a more practical balance between credential exposure and job debugging needs — future implementation may adjust.
- Bootstrap credentials mounted as **files** (not env vars) to prevent leaking
  in process listings or crash dumps.
- Init Job ServiceAccount names (`<service>-init`) must never be reused by
  Deployments/StatefulSets in the same namespace.

Init Jobs use scoped bootstrap Vault roles to read only the admin credentials
they need. After the Job completes, it self-destructs via TTL. The bootstrap
role remains but is only mountable by Job ServiceAccounts — not by service Pods.

### Idempotency

All init Job operations use upsert semantics:

| System | Method | Behavior |
|--------|--------|----------|
| Vault policy | `vault policy write` | Overwrites existing |
| Vault K8s auth role | `vault write auth/kubernetes/role/` | Overwrites existing |
| Keycloak OIDC client | GET then PUT/POST | Upsert |
| MinIO bucket | `mc mb --ignore-existing` | Skips if exists |
| MinIO access key | `mc admin user svcacct ls` then add/update | Upsert |
| Vault KV secret | `vault kv put` | Overwrites existing |

Re-running `deploy.sh` re-creates the Job (Fleet pushes new spec), which
upserts all resources safely.

## What vault-init Becomes (Minimal)

Current vault-init creates ~15 policies, ~12 auth roles, all namespace
SecretStores. After refactoring:

**vault-init creates ONLY:**
1. PKI engine (`pki`, `pki_int`)
2. KV v2 engine (`kv`)
3. Kubernetes auth backend
4. **Pre-created template policies** per namespace:
   - `eso-reader-<ns>` — read `kv/data/services/<ns>/*`
   - `eso-writer-<ns>` — write `kv/data/services/<ns>/*`
5. **Scoped bootstrap auth roles** per namespace (3 variants):
   - `bootstrap-base-<ns>` — write `kv/services/<ns>/*`, bind policies
   - `bootstrap-keycloak-<ns>` — above + read `kv/admin/keycloak`
   - `bootstrap-minio-<ns>` — above + read `kv/admin/minio`
   (Services needing both get both roles)
6. Seeds admin credentials to Vault KV:
   - `kv/admin/keycloak` (Keycloak admin password)
   - `kv/admin/minio` (MinIO root user + password)
7. **ClusterSecretStore** for bootstrap — accessible from any namespace,
   uses a cluster-wide ESO auth role that can read `kv/admin/*`. This
   solves the chicken-and-egg problem: init Jobs need bootstrap creds
   before namespace-scoped SecretStores exist.

Init Jobs bind the pre-created `eso-reader-<ns>` and `eso-writer-<ns>`
policies to namespace-scoped auth roles, then create namespace-scoped
SecretStores as their first operation.

## What keycloak-config Becomes (keycloak-realm-init)

Current keycloak-config creates all 14 OIDC clients. After refactoring:

**keycloak-realm-init creates ONLY:**
1. Platform realm (`platform`) with SSO configuration
   - `ssoSessionIdleTimeout`: 8h
   - `ssoSessionMaxLifespan`: 10h
   - Access token lifetime: 300s
2. Vault OIDC client + Vault OIDC auth roles (`default`, `admin`)
3. Rancher OIDC client + auth provider configuration
4. Traefik OIDC client (oauth2-proxy, pre-existing infrastructure)
5. Hubble OIDC client (oauth2-proxy, pre-existing infrastructure)
6. Keycloak's own admin realm configuration

These five are infrastructure services that exist before per-service bundles
run. All other OIDC clients (Grafana, Prometheus, Harbor, GitLab, ArgoCD,
Argo Rollouts, Argo Workflows, Alertmanager) are created by per-service init
Jobs.

## What minio-init Becomes (Deleted)

The centralized minio-init Job is removed entirely. Each service's init Job
creates its own MinIO bucket and access key:

- `harbor-init` creates `harbor` bucket + `harbor-sa` access key
- `gitlab-init` creates 9 GitLab buckets + `gitlab-sa` access key
- CNPG backup bucket (`cnpg-backups`) + `cnpg-admin` key created by a
  dedicated init Job in the database namespace (or by vault-init since CNPG
  is foundational)

One access key per service (not per bucket). GitLab requires a single S3
credential for all 9 bucket types — the Helm chart does not support per-bucket
credentials.

## New Bundle: 11-infra-auth

Deploys oauth2-proxy instances for infrastructure services that are deployed
before the identity bundle:

- Traefik dashboard oauth2-proxy + Gateway + HTTPRoute (deploys into `kube-system`)
- Hubble UI oauth2-proxy + Gateway + HTTPRoute (deploys into `monitoring`)
- Vault UI oauth2-proxy + Gateway + HTTPRoute (deploys into `vault`)

Each proxy deploys into the existing namespace of the service it fronts — no
new namespace created. Reads OIDC client secrets from Vault (created by
keycloak-realm-init) via the ClusterSecretStore.

No init Job needed — OIDC clients already created by keycloak-realm-init,
and bootstrap SecretStores already exist for these namespaces.

Depends on: `keycloak-realm-init` (OIDC clients exist in Vault)

## Per-Service Init Job Scope

| Service | Vault Policy | OIDC Client | MinIO Bucket | Redis Password | DB Password | Other |
|---------|-------------|-------------|--------------|----------------|-------------|-------|
| keycloak | Yes | No (it IS Keycloak) | No | No | Yes (keycloak-pg) | Admin password |
| grafana | Yes | Yes | No | No | Yes (grafana-pg) | Admin password |
| prometheus | Yes | Yes (oauth2-proxy) | No | No | No | -- |
| alertmanager | Yes | Yes (oauth2-proxy) | No | No | No | -- |
| loki | Yes | No | Future | No | No | -- |
| alloy | Yes | No | No | No | No | -- |
| harbor | Yes | Yes | 1 bucket, 1 key | Yes (valkey) | Yes (harbor-pg) | Admin, S3 creds |
| minio | Yes | No | No (it IS MinIO) | No | No | Root creds |
| argocd | Yes | Yes | No | No | No | Server secret key |
| argo-rollouts | Yes | Yes (oauth2-proxy) | No | No | No | -- |
| argo-workflows | Yes | Yes (oauth2-proxy) | No | No | No | -- |
| gitlab | Yes | Yes | 9 buckets, 1 key | Yes (redis) | Yes (gitlab + praefect) | Runner tokens, registry creds |
| gitlab-runners | Yes | No | No | No | No | Runner registration token |

**Services with NO init Job** (pure operators / infrastructure):
- All 00-operators (CNPG, Redis Operator, node-labeler, autoscalers, Gateway API CRDs)
- cert-manager, Vault, ESO (bundle 05 — they ARE the bootstrap)

## Revised Bundle Structure

**Current: 7 bundle groups, 48 HelmOps**
**Proposed: 8 bundle groups**

### Bundles that change

| Bundle | Current | Proposed |
|--------|---------|---------|
| 05-pki | vault-init creates ALL policies/roles | vault-init minimal (PKI, KV, auth, bootstrap roles) |
| 10-identity | keycloak-config creates 14 OIDC clients | keycloak-realm-init creates realm + 5 infra clients |
| 11-infra-auth | Does not exist | NEW: oauth2-proxy for Traefik, Hubble, Vault UI |
| 20-monitoring | monitoring-secrets creates all creds | Per-service init Jobs (grafana-init, prometheus-init, etc.) |
| 30-harbor | minio-init creates all buckets, harbor-credentials separate | harbor-init creates bucket + all creds. minio-init deleted. |
| 40-gitops | argocd-credentials separate, argocd-gitlab-setup creates per-repo | argocd-init replaces credentials. gitlab-setup creates deployment repo + ApplicationSet only. |
| 50-gitlab | gitlab-credentials separate | gitlab-init replaces credentials + creates 9 buckets + OIDC |

### Resources deleted

| Current | Replaced By |
|---------|-------------|
| keycloak-config Job (14 clients) | keycloak-realm-init (5 clients) + per-service init Jobs |
| minio-init Job (all buckets) | Per-service init Jobs |
| monitoring-secrets bundle | Per-service init Jobs |
| harbor-credentials bundle | harbor-init Job |
| gitlab-credentials bundle | gitlab-init Job |
| argocd-credentials bundle | argocd-init Job |

## Revised Deployment Order

```
00-operators
  CNPG, Redis Operator, Gateway API CRDs, autoscalers
  (unchanged)
       |
05-pki-secrets
  Vault (minimal init), cert-manager, ESO
  vault-init: PKI, KV v2, K8s auth, bootstrap roles
  Seeds admin creds: kv/admin/keycloak, kv/admin/minio
       |
10-identity
  keycloak-init Job: Vault policy, DB password
  CNPG keycloak-pg: reads DB creds from Vault
  Keycloak app: depends on DB ready
  keycloak-realm-init: realm + 5 OIDC clients
       |
11-infra-auth
  oauth2-proxy for Traefik, Hubble, Vault UI
  Reads OIDC secrets from Vault
       |
  (bundles 20-50 can deploy after 11)
       |
20-monitoring
  grafana-init, prometheus-init, alertmanager-init, loki-init, alloy-init
  Then: CNPG grafana-pg, Prometheus stack, Loki, Alloy, Grafana
       |
30-harbor
  harbor-init Job: Vault policy, OIDC, MinIO bucket + key,
    Valkey password, DB password, admin password, S3 creds
  Then: MinIO server, CNPG harbor-pg, Valkey, Harbor core
       |
40-gitops
  argocd-init, rollouts-init, workflows-init
  Then: ArgoCD, Rollouts, Workflows
  argocd-gitlab-setup: deployment repo + ApplicationSet (waits for GitLab)
       |
50-gitlab
  gitlab-init Job: Vault policy, OIDC, 9 MinIO buckets + key,
    Redis password, DB password (gitlab + praefect)
  Then: CNPG gitlab-pg, Redis, GitLab core, Runners
```

**Key improvement:** Bundles 20, 30, 40 no longer block on monolithic
keycloak-config. Each service's init Job creates its own OIDC client. The
only shared gate is keycloak-realm-init (realm + 5 infra clients).

**Deep-dive fixes included:**
- No more `minio -> gitlab-credentials` forward reference
- No more `gitlab-credentials -> gitlab-redis` circular reference
- `identity-keycloak-config` bottleneck eliminated

## MinimalCD Developer Experience

### Scope Boundary

| What | Managed By | Why |
|------|-----------|-----|
| Platform infrastructure (Vault, Keycloak, Harbor, monitoring, GitOps, GitLab) | Fleet GitOps | Complex dependency chains, HelmOp lifecycle, multi-phase deploy |
| Developer applications | ArgoCD + ApplicationSet | Simple, self-service, MR-driven, auto-discovery |

### Deployment Repo

A single GitLab repo (`platform-deployments`) with standardized directory
structure. ArgoCD watches with a Git Generator ApplicationSet — auto-discovers
any new `services/<name>/` directory and deploys it.

```
platform-deployments/
  templates/
    service-template/              # Scaffold for new services
      kustomization.yaml
      CHECKLIST.md                 # Dependency matrix to fill out
      init-job.yaml                # Bootstrap Job (Vault, OIDC, MinIO, creds)
      namespace.yaml               # Namespace with ResourceQuota + LimitRange
      serviceaccount.yaml          # Per-service SA (least privilege)
      deployment.yaml              # Standard K8s Deployment (pick one)
      rollout.yaml                 # Argo Rollout canary/blue-green (pick one)
      service.yaml                 # K8s Service (HTTPRoute target)
      gateway.yaml                 # TLS via cert-manager shim
      httproute.yaml               # Routing
      external-secrets.yaml        # Read credentials from Vault
      secretstore.yaml             # Namespace-scoped Vault SecretStore
      configmap.yaml               # Non-secret application config
      hpa.yaml                     # HorizontalPodAutoscaler
      pdb.yaml                     # PodDisruptionBudget
      volume-autoscaler.yaml       # PVC auto-growth
      servicemonitor.yaml          # Prometheus scraping
      workflow-templates/           # Argo Workflow templates (CI/batch/pipeline)
      analysis-template.yaml       # Custom AnalysisTemplate for Rollouts
  services/
    <service-name>/                # One directory per deployed service
      ...                          # Customized from template
```

All templates include `readinessProbe` and `livenessProbe` stubs. Deployment
and Rollout templates include `imagePullSecrets` referencing Harbor registry
credentials and optional root CA volume mount for internal HTTPS calls.

### Developer Workflow

1. Copy `templates/service-template/` to `services/my-app/`
2. Fill in `CHECKLIST.md` (dependency matrix)
3. Customize init-job.yaml based on checked dependencies
4. Choose deployment strategy:
   - `deployment.yaml` for standard rolling updates
   - `rollout.yaml` for Argo Rollouts canary/blue-green
   - `workflow-templates/` for Argo Workflows batch/CI pipelines
5. Open MR to `platform-deployments` repo
6. Platform team reviews
7. MR merges, ArgoCD auto-discovers, deploys

### ArgoCD AppProject (Namespace Isolation)

Developer applications deploy into a restricted AppProject that prevents
access to platform namespaces and cluster-scoped resources:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: developer-apps
  namespace: argocd
spec:
  sourceRepos:
    - https://gitlab.example.com/platform/platform-deployments.git
  destinations:
    - namespace: 'app-*'           # Developer namespaces must use app- prefix
      server: https://kubernetes.default.svc
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota
    - group: ''
      kind: LimitRange
  clusterResourceWhitelist: []     # Deny all cluster-scoped resources
```

Platform namespaces (vault, keycloak, monitoring, harbor, argocd, gitlab,
minio, cert-manager, kube-system) are protected by the `app-*` prefix
requirement.

### ArgoCD ApplicationSet

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform-services
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: https://gitlab.example.com/platform/platform-deployments.git
        revision: main
        directories:
          - path: services/*
  template:
    metadata:
      name: '{{path.basename}}'
    spec:
      project: developer-apps     # Restricted project, not default
      source:
        repoURL: https://gitlab.example.com/platform/platform-deployments.git
        targetRevision: main
        path: '{{path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: 'app-{{path.basename}}'  # app- prefix enforced
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - PruneLast=true         # Delete resources last during sync
```

**Namespace provisioning**: Namespaces are NOT auto-created by ArgoCD. The
service's init Job creates the namespace with required ResourceQuota,
LimitRange, and labels. ArgoCD SyncWave annotations order deployment:
init Job at wave -1, infrastructure at wave 0, application at wave 1.

**Stateful resource protection**: PVCs and CNPG Cluster CRs must include
`argocd.argoproj.io/sync-options: Delete=false` annotation to prevent
accidental deletion if a developer removes their service directory.

### Deployment Strategy Options

Developers choose one:

**Standard Deployment** (default):
- `deployment.yaml` with RollingUpdate strategy
- Suitable for stateless services with simple rollout needs

**Argo Rollout — Canary**:
- `rollout.yaml` with canary strategy + steps (e.g., 20%, pause, 50%, pause, 100%)
- Reference pre-built AnalysisTemplates (error-rate, latency-check, success-rate)
- Automatic rollback on failed analysis

**Argo Rollout — Blue/Green**:
- `rollout.yaml` with blueGreen strategy
- Preview service for pre-promotion testing
- Automatic or manual promotion

**Argo Workflows**:
- `workflow-templates/` for batch jobs, data pipelines, CI workflows
- Triggered on schedule (CronWorkflow) or manually via ArgoCD UI / CLI
- Templates reusable across services
- Note: Argo Events is not currently deployed. Webhook-triggered workflows
  require adding Argo Events to the platform (future enhancement).

### Developer Dependency Matrix Template

Developers fill this out when onboarding:

```
Service: _______________
Namespace: app-_______________
Team: _______________
Container image: harbor.example.com/<upstream>/<image>:<tag>

Workload Configuration:
  Node selector:               workload-type: general / database
  Replicas:                    ___
  CPU request:                 ___ (e.g., 100m)
  Memory request:              ___ (e.g., 128Mi)
  Deployment strategy:         [ ] Deployment  [ ] Argo Rollout (canary/blue-green)

External Dependencies:
  [ ] PostgreSQL (CNPG)        DB name: ___, size: ___, node: database
  [ ] Redis/Valkey             Sentinel: yes/no, size: ___
  [ ] MinIO bucket             Bucket name: ___, estimated size: ___
  [ ] Keycloak OIDC client     Redirect URI: ___, PKCE: S256/disabled
  [ ] Gateway + HTTPRoute      FQDN: ___, TLS: vault-issuer
  [ ] TCPRoute (non-HTTP)      Port: ___, protocol: ___
  [ ] HPA                      Min: ___, Max: ___, CPU target: ___%
  [ ] VolumeAutoscaler         Threshold: ___%, max size: ___
  [ ] PodDisruptionBudget      minAvailable: ___ or maxUnavailable: ___
  [ ] oauth2-proxy             For services without native OIDC
  [ ] Root CA trust            Calls internal HTTPS endpoints: yes/no
  [ ] ServiceMonitor           Metrics port: ___, path: /metrics
  [ ] Argo Rollout             Strategy: canary / blue-green
  [ ] Argo Workflow templates  Use case: CI / batch / pipeline
  [ ] Custom init steps        Describe: ___

Rollback plan: _______________

Vault policy (always required): auto-created by init Job
ESO roles (always required): auto-created by init Job
Namespace (always required): created by init Job with ResourceQuota + LimitRange

Pre-Built Analysis Templates (for Argo Rollouts):
  - success-rate-check: Prometheus query for HTTP 5xx < threshold
  - error-rate-check: Prometheus query for error rate < threshold
  - latency-p99-check: Prometheus query for p99 latency < threshold
```

### Fleet vs ArgoCD Decision Matrix

Developers deploying resources need to know which tool manages what:

| Resource Type | Managed By | Reason |
|---|---|---|
| CNPG Cluster for app DB | ArgoCD (in service dir) | App-owned database |
| CNPG Operator | Fleet (bundle 00) | Shared operator, cluster-wide |
| Redis/Valkey for app | ArgoCD (in service dir) | App-owned cache |
| Redis Operator | Fleet (bundle 00) | Shared operator |
| Gateway + HTTPRoute for app | ArgoCD (in service dir) | App-owned ingress |
| Traefik (Gateway controller) | Fleet (system-level) | Shared infrastructure |
| ExternalSecret for app | ArgoCD (in service dir) | App-owned secret refs |
| ESO controller | Fleet (bundle 05) | Shared infrastructure |
| Namespace-scoped SecretStore | ArgoCD (created by init Job) | App-owned Vault access |
| ClusterSecretStore (bootstrap) | Fleet (bundle 05) | Shared bootstrap access |

## Init Job Template

Standard pattern for all per-service init Jobs:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: <service>-init
  namespace: <service-namespace>
  labels:
    app.kubernetes.io/name: <service>-init
    app.kubernetes.io/component: bootstrap
spec:
  ttlSecondsAfterFinished: 3600    # 1h — minimize credential exposure
  backoffLimit: 5
  template:
    spec:
      serviceAccountName: <service>-init
      nodeSelector:
        workload-type: general
      restartPolicy: OnFailure
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: init
          image: <IMAGE_ALPINE_K8S>
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            readOnlyRootFilesystem: false
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
          env:
            - name: VAULT_ADDR
              value: <VAULT_INTERNAL_URL>
          volumeMounts:
            - name: bootstrap-creds
              mountPath: /secrets
              readOnly: true
          command: ["/bin/bash", "-euo", "pipefail", "-c"]
          args:
            - |
              # Authenticate to Vault via K8s auth (NEVER use root token)
              SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
              export VAULT_TOKEN=$(vault write -field=token \
                auth/kubernetes/login \
                role="bootstrap-keycloak-<namespace>" \
                jwt="${SA_TOKEN}")

              # Step 1: Bind pre-created eso-reader/eso-writer policies
              #         to namespace-scoped auth roles
              # Step 2: Create namespace-scoped ESO SecretStore
              # Step 3: Create Keycloak OIDC client (if needed)
              #         (reads admin password from /secrets/keycloak-admin-password)
              # Step 4: Create MinIO bucket + access key (if needed)
              #         (reads root creds from /secrets/minio-*)
              # Step 5: Generate passwords (admin, Redis, DB, etc.)
              # Step 6: Write all credentials to Vault KV
              echo "Init complete for <service>"
      volumes:
        - name: bootstrap-creds
          secret:
            secretName: <service>-bootstrap-admin
```

**Bootstrap credentials as files** (not env vars): The `<service>-bootstrap-admin`
K8s Secret is created by an ExternalSecret referencing the ClusterSecretStore.
It reads from `kv/admin/keycloak` and/or `kv/admin/minio` depending on which
bootstrap roles the service needs. Mounted read-only at `/secrets/`.

**What init Jobs do:**
- Credential generation + external API calls (Vault, Keycloak, MinIO)

**What init Jobs do NOT do:**
- Create CNPG clusters (declarative manifest)
- Create Redis/Valkey instances (declarative manifest)
- Create Gateway/HTTPRoute (declarative manifest, TLS via cert-manager shim)
- Create HPA/VolumeAutoscaler (declarative manifest)
- Create ESO ExternalSecrets (declarative manifest)
- Handle TLS certificates (cert-manager Gateway API shim)

## Bootstrap Credential Flow

```
vault-init (Layer 0)
  Seeds admin creds into Vault KV:
    kv/admin/keycloak   (Keycloak admin password)
    kv/admin/minio      (MinIO root user + password)
  Creates ClusterSecretStore (bootstrap-vault)
    accessible from any namespace
  Pre-creates template policies: eso-reader-<ns>, eso-writer-<ns>
  Creates scoped bootstrap auth roles per namespace
       |
Per-namespace ExternalSecret (via ClusterSecretStore)
  Reads kv/admin/keycloak and/or kv/admin/minio
  Creates K8s Secret: <service>-bootstrap-admin
       |
Init Job mounts <service>-bootstrap-admin as files at /secrets/
  Authenticates to Vault via K8s auth (SA token exchange)
  Step 1: Binds pre-created policies to namespace auth roles
  Step 2: Creates namespace-scoped ESO SecretStore
  Step 3: Creates external resources (OIDC, MinIO, etc.)
  Step 4: Generates + writes credentials to Vault KV
  Job completes, TTL auto-deletes after 1h
       |
Regular ExternalSecrets (using namespace SecretStore + eso-reader role)
  Read from kv/services/<service>/*
  Create K8s Secrets for service consumption
```

### Solving the Chicken-and-Egg Problem

The ClusterSecretStore eliminates the chicken-and-egg:
- vault-init creates ONE ClusterSecretStore accessible from ALL namespaces
- Bootstrap ExternalSecrets in any namespace can reference it immediately
- Init Jobs read bootstrap creds → create namespace-scoped SecretStores
- After init Job, service uses namespace-scoped SecretStore (not ClusterSecretStore)

### Two-Phase Sub-Bundle Ordering

Within each bundle group, init Jobs and infrastructure CRs must be ordered
via Fleet `dependsOn`. Each service uses **two or three sub-bundles**:

```
<service>-init       (Job — creates creds, writes to Vault)
       ↓ dependsOn
<service>-infra      (CNPG Cluster, Redis CR, ExternalSecrets)
       ↓ dependsOn
<service>-core       (Helm chart / application Deployment)
```

This prevents the race condition where CNPG tries to create a database before
credentials exist. Example for Harbor:

```
harbor-init          dependsOn: keycloak-realm-init
       ↓
harbor-infra         dependsOn: harbor-init
  (CNPG harbor-pg, Valkey CRs, ExternalSecrets, MinIO server)
       ↓
harbor-core          dependsOn: harbor-infra
  (Harbor Helm chart, HTTPRoute, HPA, manifests)
```

## GatewayAPI and TLS

TLS certificates are NOT an init Job concern. The existing pattern works:

1. Each service deploys a **Gateway** resource with annotation:
   `cert-manager.io/cluster-issuer: vault-issuer`
2. cert-manager Gateway API shim auto-creates TLS Certificate
3. **HTTPRoute** references the Gateway's HTTPS listener

No separate Certificate CRs needed. Per-service Gateway + HTTPRoute are
declarative manifests in Layer 2.

**Experimental CRDs** (TCPRoute, TLSRoute) remain in `00-operators/gateway-api-crds`
for services needing non-HTTP protocols (e.g., GitLab SSH via TCPRoute).

## Design Decisions

### ADR-1: Per-Service Init Jobs Over Centralized Jobs
- **Status**: Accepted
- **Decision**: Each service owns a single init Job for all external deps
- **Context**: Centralized Jobs created bottlenecks and required modifying shared
  resources to add new services
- **Consequences**: More Jobs to maintain, but each is self-contained and testable
- **Alternatives**: Multiple Jobs per dep type (rejected — too many Jobs)
- **DRY consideration**: A shared shell function library (ConfigMap `init-lib.sh`)
  is RECOMMENDED to avoid duplicating Vault auth, Keycloak API calls, and MinIO
  operations across 13+ init Jobs. Each Job remains self-contained (owns its
  script body) but sources shared utility functions. This is an implementation
  detail — the design does not mandate it, but strongly recommends it to prevent
  copy-paste drift when Vault/Keycloak APIs change.

### ADR-2: Vault-Init Minimal Bootstrap
- **Status**: Accepted
- **Decision**: vault-init only creates engines, auth backend, and bootstrap roles
- **Context**: Per-service ownership requires services to create their own policies
- **Consequences**: vault-init is simpler, but each service must create its own
  Vault policy (handled by init Job)

### ADR-3: ESO-Based Credential Rotation
- **Status**: Accepted
- **Decision**: ESO PushSecret with updatePolicy: Replace handles rotation
- **Context**: Services need write access for rotation without exposing admin creds
- **Consequences**: ESO controllers have write access via eso-writer role. No
  CronJobs needed.

### ADR-4: MinimalCD Single Deployment Repo
- **Status**: Accepted
- **Decision**: Single platform-deployments GitLab repo with ArgoCD ApplicationSet
- **Context**: Developer self-service for application deployments
- **Consequences**: Fleet handles platform infra, ArgoCD handles apps. Developers
  just open MRs.

### ADR-5: Argo Rollouts and Workflows as First-Class Options
- **Status**: Accepted
- **Decision**: Developer template includes Rollout and Workflow options alongside
  standard Deployments
- **Context**: Platform supports canary/blue-green and workflow orchestration
- **Consequences**: Developers choose deployment strategy per service. Pre-built
  AnalysisTemplates available for Rollouts.

### ADR-6: Infrastructure Auth Separated from Monitoring
- **Status**: Accepted
- **Decision**: New 11-infra-auth bundle for Traefik/Hubble/Vault oauth2-proxy
- **Context**: Infrastructure services deployed before monitoring shouldn't depend
  on monitoring stack
- **Consequences**: New bundle to maintain, but cleaner dependency chain

### ADR-7: ClusterSecretStore for Bootstrap
- **Status**: Accepted
- **Decision**: vault-init creates a ClusterSecretStore for bootstrap credentials
- **Context**: Per-namespace SecretStores cannot exist before the init Job creates
  them, but the init Job needs bootstrap credentials from Vault (chicken-and-egg)
- **Consequences**: ClusterSecretStore is cluster-wide but scoped to `kv/admin/*`
  read-only. After init Job creates namespace SecretStore, services use that instead.

### ADR-8: Pre-Created Vault Policies (No Dynamic Policy Creation)
- **Status**: Accepted
- **Decision**: vault-init pre-creates `eso-reader-<ns>` and `eso-writer-<ns>`
  policies. Init Jobs can only bind existing policies, not create new ones.
- **Context**: Allowing init Jobs to create arbitrary Vault policies enables
  privilege escalation if a container is compromised
- **Consequences**: Adding a new namespace requires updating vault-init's namespace
  list. Acceptable since new namespaces are a platform-level change.

## Existing Bug: Vault OIDC Default Role

**IMPORTANT**: The current Vault OIDC `default` role grants `admin-policy`
(full sudo on all Vault paths) to ANY authenticated Keycloak user — not just
`platform-admins` group members. This is a privilege escalation vulnerability
that must be fixed during implementation:

- Remove `admin-policy` from the `default` role
- The `admin` role (restricted to `platform-admins` group) already has admin access
- This fix should be applied in `keycloak-realm-init` when it configures Vault OIDC

## Admin Credential Rotation

Admin credentials seeded by vault-init (`kv/admin/keycloak`, `kv/admin/minio`)
must have a documented rotation policy:

| Credential | Rotation Schedule | Method |
|---|---|---|
| Keycloak admin password | 90 days | Manual: update in Vault, restart Keycloak |
| MinIO root credentials | 90 days | Manual: update in Vault, restart MinIO |

These are infrastructure-level credentials used only by init Jobs. Rotation
requires coordination with the platform team since active init Jobs would
fail if credentials change mid-flight.

## Review Findings Incorporated

This design was reviewed by four specialized agents. Key changes made:

| Finding | Source | Resolution |
|---|---|---|
| Scoped bootstrap-writer per dependency type | Security, K8s Infra, Platform Eng | Split into bootstrap-keycloak/minio/base roles |
| No arbitrary policy creation by init Jobs | Security | Pre-create policies in vault-init |
| K8s auth for init Jobs, not root token | Security, K8s Infra, Platform Eng | Template uses `vault write auth/kubernetes/login` |
| ClusterSecretStore for bootstrap | Platform Eng | Eliminates chicken-and-egg problem |
| Two-phase sub-bundles with dependsOn | K8s Infra | Prevents CNPG/Redis race conditions |
| Restricted ArgoCD AppProject | K8s Infra, Security | Namespace isolation, no cluster-scoped resources |
| Remove CreateNamespace=true | K8s Infra | Init Job creates namespace with quotas |
| Job TTL reduced to 1h | Security | Minimize credential exposure window |
| Secrets as files not env vars | Security | Prevent leaking in process listings |
| SecurityContext on init Jobs | K8s Infra | runAsNonRoot, drop ALL capabilities |
| Add Service, SA, PDB, ServiceMonitor to template | Platform Dev | Complete developer template |
| Shared init library recommended | Platform Dev | DRY — prevent copy-paste across 13 Jobs |
| Fleet vs ArgoCD decision matrix | Platform Dev | Clear guidance for developers |
| Vault OIDC default role bug | Security | Fix during implementation |
| PruneLast + Delete=false on PVCs | K8s Infra | Protect stateful data from accidental deletion |
