# Service Ownership Model — Implementation Progress

> **Purpose:** Checkpoint file for agentic implementation across context windows.
> On context loss, read this file + the full implementation plan at:
> `docs/plans/2026-03-11-service-ownership-implementation-plan.md`

## Current State

**Last checkpoint:** Not started
**Current phase:** Phase 1
**Current task:** Not started
**BUNDLE_VERSION:** 1.0.51 (starting value)

## Phase Progress

| Phase | Name | Status | Notes |
|-------|------|--------|-------|
| 1 | Vault-Init Minimal | NOT STARTED | |
| 2 | Shared Init Library | NOT STARTED | |
| 3 | Keycloak Realm Init | NOT STARTED | |
| 4 | 11-Infra-Auth Bundle | NOT STARTED | |
| 5 | Per-Service Init (Identity+Monitoring) | NOT STARTED | |
| 6 | Per-Service Init (Harbor) | NOT STARTED | |
| 7 | Per-Service Init (GitOps) | NOT STARTED | |
| 8 | Per-Service Init (GitLab) | NOT STARTED | |
| 9 | MinimalCD Developer Experience | NOT STARTED | |

## Task-Level Checkpoints

### Phase 1
- [ ] Task 1.1: Pre-created template policies in vault-init-job.yaml
- [ ] Task 1.2: ClusterSecretStore for bootstrap
- [ ] Task 1.3: Deploy cycle test

### Phase 2
- [ ] Task 2.1: Create init-lib.sh (canonical source)
- [ ] Task 2.1: Create render step for per-bundle ConfigMap embedding

### Phase 3
- [ ] Task 3.1: Create keycloak-realm-init Job
- [ ] Task 3.1: Fix Vault OIDC default role bug
- [ ] Task 3.1: Replace root token auth with K8s auth
- [ ] Task 3.1: Update push-bundles.sh + deploy-fleet-helmops.sh

### Phase 4
- [ ] Task 4.1: Create 11-infra-auth directory structure
- [ ] Task 4.1: Move files from ingress-auth + monitoring-secrets
- [ ] Task 4.1: Update push-bundles.sh + deploy-fleet-helmops.sh

### Phase 5
- [ ] Task 5.1: keycloak-init Job
- [ ] Task 5.2: grafana-init Job
- [ ] Task 5.3: prometheus-init Job
- [ ] Task 5.4: alertmanager-init Job
- [ ] Task 5.5: loki-init + alloy-init Jobs
- [ ] Task 5.6: Remove monitoring-secrets + migrate resources
- [ ] Task 5.7: Deploy cycle test

### Phase 6
- [ ] Task 6.1: harbor-init Job
- [ ] Task 6.2: Remove harbor-credentials + migrate reader ESOs
- [ ] Task 6.3: Refactor minio bundle
- [ ] Task 6.4: Update HELMOP_DEFS
- [ ] Task 6.5: Deploy cycle test

### Phase 7
- [ ] Task 7.1: argocd-init Job
- [ ] Task 7.2: rollouts-init + workflows-init Jobs
- [ ] Task 7.3: Remove argocd-credentials
- [ ] Task 7.4: Simplify argocd-gitlab-setup
- [ ] Task 7.5: Deploy cycle test

### Phase 8
- [ ] Task 8.1: gitlab-init Job
- [ ] Task 8.2: Remove gitlab-credentials
- [ ] Task 8.3: Fix minio dependency on gitlab-credentials
- [ ] Task 8.4: Fix gitlab-redis dependency
- [ ] Task 8.5: Full deploy cycle test

### Phase 9
- [ ] Task 9.1: platform-deployments repo structure
- [ ] Task 9.2: Developer template directory
- [ ] Task 9.3: ArgoCD AppProject + ApplicationSet
- [ ] Task 9.4: Verify AnalysisTemplates
- [ ] Task 9.5: Developer CHECKLIST.md
- [ ] Task 9.6: Test MinimalCD flow
- [ ] Task 9.7: Final commit

## Blockers / Issues

None yet.

## Key References

- **Implementation plan:** `docs/plans/2026-03-11-service-ownership-implementation-plan.md`
- **Design spec:** `docs/plans/2026-03-11-service-ownership-model-design.md`
- **Deploy script:** `scripts/deploy-fleet-helmops.sh`
- **Bundle push:** `scripts/push-bundles.sh`
- **Environment:** `.env` (BUNDLE_VERSION)
- **Vault-init:** `05-pki-secrets/vault-init/manifests/vault-init-job.yaml`
- **Keycloak-config:** `10-identity/keycloak-config/manifests/keycloak-config-job.yaml`

## Recovery Instructions

If context is lost:
1. Read this file for last checkpoint
2. Read the full implementation plan
3. Resume from the current phase/task marked above
4. After completing each task, update this file
5. After completing each phase, run deploy test and update status
