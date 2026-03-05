# GitLab Bundle Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy self-hosted GitLab EE (Ultimate) with Praefect/Gitaly HA, K8s runners, and CI templates — all consolidated under services/gitlab/.

**Architecture:** GitLab Helm chart with external CNPG PostgreSQL, Redis Sentinel, and Keycloak OIDC. Runners use K8s executor (pod-per-job). SSH via TCP Gateway listener. CI templates as shared pipeline definitions.

**Tech Stack:** GitLab Helm chart (EE), CNPG PostgreSQL 17, OpsTree Redis v7.0.15, Gateway API v1 (TCP + HTTPS), Kustomize.

**Source reference:** `../rke2-cluster-via-rancher/services/gitlab/`, `../rke2-cluster-via-rancher/services/gitlab-runners/`, `../rke2-cluster-via-rancher/services/gitlab-ci-templates/`

**Conventions:** Requests only (no limits), HPA via Helm, VolumeAutoscaler CRs, anti-affinity, node selectors (database/compute/general).

---

## Task 1: GitLab Namespace + Gateway + TCPRoute SSH

**Files:**
- Create: `services/gitlab/namespace.yaml`
- Create: `services/gitlab/gateway.yaml`
- Create: `services/gitlab/tcproute-ssh.yaml`

Copy from source. The gateway has both HTTPS (8443) and TCP SSH (2222) listeners. The TCPRoute maps port 2222 to gitlab-shell:22.

Commit: `feat: add GitLab namespace, gateway (HTTPS+SSH), and TCP route`

---

## Task 2: GitLab Helm Values

**Files:**
- Create: `services/gitlab/values-rke2-prod.yaml`

Copy from source. Remove ALL `limits:` blocks across every component (webservice, sidekiq, gitaly, praefect, shell, kas, exporter, migrations, toolbox, nginx). Keep `requests:` only. Keep all CHANGEME_* placeholders.

Commit: `feat: add GitLab Helm values (EE, external PG/Redis/OIDC, requests only)`

---

## Task 3: CNPG PostgreSQL + Scheduled Backup

**Files:**
- Create: `services/gitlab/cloudnativepg-cluster.yaml`
- Create: `services/gitlab/cloudnativepg-scheduled-backup.yaml`

Copy from source. Remove limits from CNPG cluster. Note: This cluster uses PostgreSQL 17 (not 16.6 like Harbor/Keycloak) and requires extensions (pg_trgm, btree_gist, plpgsql, amcheck, pg_stat_statements) plus a separate praefect database.

Commit: `feat: add GitLab CNPG PostgreSQL (3-instance, 50Gi, Praefect DB)`

---

## Task 4: Redis Sentinel + ExternalSecrets

**Files:**
- Create: `services/gitlab/redis/replication.yaml`
- Create: `services/gitlab/redis/sentinel.yaml`
- Create: `services/gitlab/redis/external-secret.yaml`

Copy from source. Remove limits from replication and sentinel. Do NOT copy secret.yaml (use ESO only).

Commit: `feat: add GitLab Redis Sentinel (3+3 HA)`

---

## Task 5: GitLab ExternalSecrets (Gitaly, Praefect, OIDC, Root)

**Files:**
- Create: `services/gitlab/gitaly/external-secret.yaml`
- Create: `services/gitlab/praefect/external-secret-dbsecret.yaml`
- Create: `services/gitlab/praefect/external-secret-token.yaml`
- Create: `services/gitlab/oidc/external-secret.yaml`
- Create: `services/gitlab/root/external-secret.yaml`

Copy from source verbatim.

Commit: `feat: add GitLab ExternalSecrets (gitaly, praefect, OIDC, root)`

---

## Task 6: GitLab Runners

**Files:**
- Create: `services/gitlab/runners/namespace.yaml`
- Create: `services/gitlab/runners/rbac.yaml`
- Create: `services/gitlab/runners/external-secret-harbor-push.yaml`
- Create: `services/gitlab/runners/shared-runner-values.yaml`
- Create: `services/gitlab/runners/security-runner-values.yaml`
- Create: `services/gitlab/runners/group-runner-values.yaml`

Copy from source (`services/gitlab-runners/`). Remove limits from runner values files.

Commit: `feat: add GitLab K8s Runners (shared, security, group)`

---

## Task 7: CI Templates

**Files:**
- Copy entire `services/gitlab-ci-templates/` to `services/gitlab/ci-templates/`

```bash
cp -r ../rke2-cluster-via-rancher/services/gitlab-ci-templates/ services/gitlab/ci-templates/
```

Commit: `feat: add GitLab CI pipeline templates (jobs, patterns, stages)`

---

## Task 8: Monitoring

**Files:**
- Copy from source `services/gitlab/monitoring/`
- Also copy runner monitoring from `services/gitlab-runners/monitoring/`

Merge both into `services/gitlab/monitoring/`.

Commit: `feat: add GitLab monitoring (ServiceMonitors, alerts, dashboards)`

---

## Task 9: VolumeAutoscalers + Root Kustomization

**Files:**
- Create: `services/gitlab/volume-autoscalers.yaml`
- Create: `services/gitlab/kustomization.yaml`

VolumeAutoscalers for: CNPG PVCs (50Gi→200Gi), Redis PVCs (10Gi→50Gi), Gitaly PVCs.

Root kustomization references all base manifests. Runners and CI templates are NOT in kustomization (deployed via Helm/git push separately).

Validate: `kubectl kustomize services/gitlab/`

Commit: `feat: add GitLab root kustomization and VolumeAutoscalers`

---

## Task 10: Deploy Script (deploy-gitlab.sh)

**Files:**
- Create: `scripts/deploy-gitlab.sh`

9-phase deploy script following established patterns. The most complex deploy script due to GitLab's migration phase (20-30 min). Sources all utils + basic-auth.

Env vars: `HELM_CHART_GITLAB`, `GITLAB_REDIS_PASSWORD`, `GITLAB_ROOT_PASSWORD`, and various Gitaly/Praefect tokens.

Commit: `feat: add deploy-gitlab.sh orchestrator (9 phases)`

---

## Task 11: Update .env.example + subst.sh

Add GitLab-specific env vars and CHANGEME tokens.

Commit: `feat: add GitLab env vars and CHANGEME tokens`

---

## Task 12: MANIFEST.yaml + README (tech-doc-keeper)

MANIFEST: All images (GitLab EE, PostgreSQL 17, Redis, Runners, Kaniko, Trivy, etc.)
README: Architecture, deployment (9 phases), post-deploy (license, OIDC), runners, CI templates, SSH access, monitoring.

Commit: `docs: add GitLab MANIFEST.yaml and README`

---

## Task 13: Security Scrub (security-sentinel)

Full scrub: org info, limits, CHANGEME coverage, kustomize build, shellcheck, image tags, hardcoded secrets. Fix ALL severity levels.

---

## Task 14: Tech-Doc Update (tech-doc-keeper)

Update top-level README, architecture.md, getting-started.md for Bundle 6.

---

## Task 15: Push + CI

Push and monitor CI. Fix any failures.
