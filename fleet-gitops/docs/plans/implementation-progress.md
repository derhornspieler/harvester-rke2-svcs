# Service Ownership Model — Implementation Progress

> **Purpose:** Checkpoint file for agentic implementation across context windows.
> On context loss, read this file + the full implementation plan at:
> `docs/plans/2026-03-11-service-ownership-implementation-plan.md`

## Current State

**Last checkpoint:** All 9 phases COMPLETE
**Current task:** Deploy cycle test + BUNDLE_VERSION bump
**BUNDLE_VERSION:** 1.0.51 (needs bump before deploy)

## Phase Progress

| Phase | Name | Status | Notes |
|-------|------|--------|-------|
| 1 | Vault-Init Minimal | COMPLETE | commit 8d58a03 |
| 2 | Shared Init Library | COMPLETE | commit a20ea66 |
| 3 | Keycloak Realm Init | COMPLETE | commit 4a79a1d |
| 4 | 11-Infra-Auth Bundle | COMPLETE | commit de0d87d |
| 5 | Per-Service Init (Identity+Monitoring) | COMPLETE | commit f507470 |
| 6 | Per-Service Init (Harbor) | COMPLETE | commit b35795c |
| 7 | Per-Service Init (GitOps) | COMPLETE | commit b35795c |
| 8 | Per-Service Init (GitLab) | COMPLETE | commit c3af4c5 |
| 9 | MinimalCD Developer Experience | COMPLETE | commit a49a95f |

## Task-Level Checkpoints

### Phase 1
- [x] Task 1.1: Pre-created template policies in vault-init-job.yaml
- [x] Task 1.2: ClusterSecretStore for bootstrap
- [ ] Task 1.3: Deploy cycle test (deferred to end)

### Phase 2
- [x] Task 2.1: Create init-lib.sh (canonical source)
- [x] Task 2.1: Create render step for per-bundle ConfigMap embedding

### Phase 3
- [x] Task 3.1: Create keycloak-realm-init Job
- [x] Task 3.1: Fix Vault OIDC default role bug
- [x] Task 3.1: Replace root token auth with K8s auth
- [x] Task 3.1: Update push-bundles.sh + deploy-fleet-helmops.sh

### Phase 4
- [x] Task 4.1: Create 11-infra-auth directory structure
- [x] Task 4.1: Move files from ingress-auth + monitoring-secrets
- [x] Task 4.1: Update push-bundles.sh + deploy-fleet-helmops.sh

### Phase 5
- [x] Task 5.1: keycloak-init Job
- [x] Task 5.2: grafana-init Job
- [x] Task 5.3: prometheus-init Job
- [x] Task 5.4: alertmanager-init Job
- [x] Task 5.5: loki-init + alloy-init Jobs
- [x] Task 5.6: Strip monitoring-secrets (removed secretstore + push-secret, kept ExternalSecrets)
- [ ] Task 5.7: Deploy cycle test (deferred to end)

### Phase 6
- [x] Task 6.1: harbor-init Job
- [x] Task 6.2: Strip harbor-credentials (removed secretstore + push-secret, kept ExternalSecrets)
- [x] Task 6.3: Refactor minio bundle (removed job-create-buckets + cross-namespace ESOs)
- [x] Task 6.4: Update push-bundles.sh + deploy-fleet-helmops.sh
- [ ] Task 6.5: Deploy cycle test (deferred to end)

### Phase 7
- [x] Task 7.1: argocd-init Job
- [x] Task 7.2: rollouts-init + workflows-init Jobs
- [x] Task 7.3: Strip argocd-credentials (removed secretstore, kept ExternalSecret)
- [x] Task 7.4: Simplify argocd-gitlab-setup (no changes needed — already correct)
- [ ] Task 7.5: Deploy cycle test (deferred to end)

### Phase 8
- [x] Task 8.1: gitlab-init Job
- [x] Task 8.2: Delete gitlab-credentials entirely
- [x] Task 8.3: Strip redis bundle (removed secretstore + push-secret)
- [x] Task 8.4: Update deploy scripts (gitlab-init replaces gitlab-credentials deps)
- [ ] Task 8.5: Full deploy cycle test (deferred to end)

### Phase 9
- [x] Task 9.1: platform-deployments repo structure (handled by argocd-gitlab-setup at runtime)
- [x] Task 9.2: Developer template directory (handled by argocd-gitlab-setup at runtime)
- [x] Task 9.3: ArgoCD AppProject + ApplicationSet
- [x] Task 9.4: AnalysisTemplates (already existed — success-rate, error-rate, latency-check)
- [x] Task 9.5: Developer CHECKLIST.md (docs/templates/CHECKLIST.md)
- [ ] Task 9.6: Test MinimalCD flow (deferred to end)
- [x] Task 9.7: Final commit

## Remaining Work

1. Bump BUNDLE_VERSION in .env
2. Run full deploy cycle test: `deploy-fleet-helmops.sh --delete && deploy-fleet-helmops.sh`
3. Validate all services deploy and function correctly
4. Run post-implementation checklist (see plan)

## Key References

- **Implementation plan:** `docs/plans/2026-03-11-service-ownership-implementation-plan.md`
- **Design spec:** `docs/plans/2026-03-11-service-ownership-model-design.md`
- **Deploy script:** `scripts/deploy-fleet-helmops.sh`
- **Bundle push:** `scripts/push-bundles.sh`
- **Environment:** `.env` (BUNDLE_VERSION)
- **Vault-init:** `05-pki-secrets/vault-init/manifests/vault-init-job.yaml`
- **Keycloak-realm-init:** `10-identity/keycloak-realm-init/manifests/realm-init-job.yaml`
