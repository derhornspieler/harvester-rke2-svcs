# Centralized Platform Deployments — Design Plan

**Date:** 2026-03-16
**Status:** Accepted (implementing)
**Depends on:** [credential-rotation-design.md](2026-03-16-credential-rotation-design.md)
**Supersedes:** [multi-env-argocd-design.md](2026-03-16-multi-env-argocd-design.md) (Pattern 2 selected)

---

## Decision

Adopt the centralized GitOps deployment repository pattern. A single
`platform/platform-deployments` GitLab repo is the only source ArgoCD watches.
All application deployments across dev/staging/prod environments are Kustomize
overlays in this repo.

This eliminates:
- Per-team ArgoCD ApplicationSets
- Per-group GitLab tokens (GAT, multiple GDTs)
- SCM Provider generator dependency
- Root user PAT (replaced by non-expiring GDT)

## Architecture

```
Developer repos (forge/svc-forge, IDP/identity-webui, etc.)
  │ CI builds image → pushes to Harbor
  │ CI updates image tag in platform-deployments
  ▼
platform/platform-deployments (single repo)
  ├── dev/<team>/<app>/kustomization.yaml      → ArgoCD auto-syncs
  ├── staging/<team>/<app>/kustomization.yaml   → ArgoCD auto-syncs after MR merge
  └── prod/<team>/<app>/kustomization.yaml      → ArgoCD manual sync
  ▼
ArgoCD (git directory generator ApplicationSets)
  ├── dev-apps     → watches dev/*/*     → deploys to dev-<app> namespaces
  ├── staging-apps → watches staging/*/* → deploys to staging-<app> namespaces
  └── prod-apps    → watches prod/*/*    → deploys to app-<app> namespaces
```

## Token Architecture (Simplified)

One token. That's it.

| Token | Type | Group | Vault Path | Expiry | Covers |
|-------|------|-------|-----------|--------|--------|
| Platform GDT | Group Deploy Token | `platform` | `kv/services/ci/gitlab-deploy-token` | **Never** | ArgoCD repo sync |

- CI pipelines use `CI_JOB_TOKEN` (built into GitLab) for their own repos
- CI pipelines use `CI_JOB_TOKEN` to push image tags to platform-deployments
- No GAT needed (no SCM Provider)
- No per-group GDTs needed (ArgoCD only watches one repo)

## ArgoCD Configuration

### AppProjects (3)

| Project | Namespaces | Sync Policy | Who Deploys |
|---------|------------|-------------|-------------|
| `developer-dev` | `dev-*` | Auto-sync + prune + selfHeal | Any developer (MR to dev/) |
| `developer-staging` | `staging-*` | Auto-sync + prune (no selfHeal) | Team + tech lead (MR) |
| `developer-apps` | `app-*` | Manual sync | Platform team approval |

### ApplicationSets (3)

All use git directory generator on `platform/platform-deployments.git`:

- `dev-apps`: discovers `dev/*/*`, auto-creates Applications
- `staging-apps`: discovers `staging/*/*`, auto-creates Applications
- `prod-apps`: discovers `prod/*/*`, auto-creates Applications (manual sync)

### Repo Credentials

Single `gitlab-repo-creds` Secret using the platform GDT.
No SCM Provider token needed.

## Bootstrap Process

`deploy.sh` handles everything automatically:

1. **GitLab admin-setup Job** creates the `platform` group and
   `platform-deployments` project (via gitlab-rails runner)
2. **seed_ci_secrets()** seeds the GDT to Vault at
   `kv/services/ci/gitlab-deploy-token`
3. **argocd-gitlab-setup Job** reads GDT from Vault, creates
   `gitlab-repo-creds` Secret in argocd namespace
4. **argocd-manifests bundle** deploys the 3 AppProjects and
   3 ApplicationSets

After bootstrap, ArgoCD watches platform-deployments and auto-discovers
any apps in the folder structure.

## CI Pipeline Flow

```
Developer pushes to forge/svc-forge-backend (main branch):
  1. CI builds image → harbor.dev.<DOMAIN>/forge/svc-forge-backend:<sha>
  2. CI clones platform/platform-deployments (using CI_JOB_TOKEN)
  3. CI runs: kustomize edit set image ... newTag=<sha>
  4. CI commits + pushes to platform-deployments
  5. ArgoCD detects change → syncs dev-svc-forge-backend within ~3min

Promote to staging:
  6. MR from dev/ overlay to staging/ overlay (team + lead approval)
  7. ArgoCD syncs after merge

Promote to prod:
  8. MR to prod/ overlay (platform team approval)
  9. ArgoCD manual sync via UI/CLI
```

## Files Created/Modified

### New files

- `fleet-gitops/40-gitops/argocd-manifests/manifests/appproject-developer-dev.yaml`
- `fleet-gitops/40-gitops/argocd-manifests/manifests/appproject-developer-staging.yaml`
- `fleet-gitops/40-gitops/argocd-manifests/manifests/applicationset-dev.yaml`
- `fleet-gitops/40-gitops/argocd-manifests/manifests/applicationset-staging.yaml`
- `fleet-gitops/40-gitops/argocd-manifests/manifests/applicationset-prod.yaml`
- `examples/platform-deployments/` (scaffold for the deployment repo)
- `docs/communications/2026-03-16-platform-deployments-migration.md`

### Modified files

- `fleet-gitops/40-gitops/argocd-gitlab-setup/manifests/argocd-gitlab-setup.yaml` (GDT-only)
- `fleet-gitops/50-gitlab/gitlab-manifests/manifests/gitlab-admin-setup.yaml` (create platform group+project)
- `fleet-gitops/scripts/deploy-fleet-helmops.sh` (GDT seeding, removed GAT)
- `fleet-gitops/.env.example` (GDT vars, removed GAT)
- `fleet-gitops/60-apps/forge/manifests/applicationset.yaml` (deprecated comment)
- `examples/microservice-demo/` (updated for platform-deployments pattern)
- `docs/developer-guide/argocd-deployment.md` (rewritten)
- `docs/developer-guide/gitlab-ci.md` (deploy stage updated)

### Non-destructive guarantees

- Existing forge ApplicationSet preserved (deprecated, not deleted)
- No changes to Harbor, GitLab, Vault, or Keycloak data
- All changes are additive (new AppProjects, new ApplicationSets)
- Old ArgoCD root PAT remains in Vault as fallback until GDT is seeded

## ADRs

### ADR-9: Centralized Platform Deployments Repo

- **Status:** Accepted
- **Decision:** Single `platform/platform-deployments` repo for all application
  deployments, watched by ArgoCD via git directory generator
- **Context:** Per-team ApplicationSets require per-group tokens and don't
  scale. Centralized repo provides audit trail, environment promotion,
  and CODEOWNERS-based approval gates.
- **Consequences:** Teams must update their CI deploy stage to push image
  tags to platform-deployments. Migration is gradual (old ApplicationSets
  stay until teams migrate).

### ADR-10: Single GDT on Platform Group

- **Status:** Accepted
- **Decision:** One Group Deploy Token on the `platform` GitLab group,
  stored at `kv/services/ci/gitlab-deploy-token`, never expires
- **Context:** ArgoCD only watches one repo. No GAT needed since
  SCM Provider is not used. CI pipelines use CI_JOB_TOKEN.
- **Consequences:** Zero credential rotation for GitLab access.
  If a new group needs ArgoCD access, add it to platform-deployments.

### ADR-11: No Auto DevOps

- **Status:** Accepted
- **Decision:** Do not use GitLab Auto DevOps
- **Context:** Auto DevOps' deploy stage deploys directly via kubectl/Helm,
  bypassing ArgoCD and the centralized deployment pattern. Build/scan
  stages overlap with existing CI templates.
- **Consequences:** Teams use platform CI templates for build/scan and
  the platform-deployments pattern for deployment.

---

## Environment Ingress & FQDN Strategy

### Problem

All three environments (dev/staging/prod) share the same Traefik ingress
and the same domain. If dev and prod apps both use `svc-forge.aegisgroup.ch`,
they clash. Staging needs its own URL for pipeline tests, canary analysis,
and smoke tests before promoting to production.

### FQDN Convention

Each environment gets a subdomain prefix:

| Environment | FQDN Pattern | Example | DNS |
|-------------|-------------|---------|-----|
| Dev | `<app>.dev.aegisgroup.ch` | `svc-forge.dev.aegisgroup.ch` | `*.dev.aegisgroup.ch` → Traefik LB IP |
| Staging | `<app>.staging.aegisgroup.ch` | `svc-forge.staging.aegisgroup.ch` | `*.staging.aegisgroup.ch` → Traefik LB IP |
| Production | `<app>.aegisgroup.ch` | `svc-forge.aegisgroup.ch` | `*.aegisgroup.ch` → Traefik LB IP (existing) |

All point to the **same Traefik LoadBalancer IP** (`192.168.48.2`). Traefik
routes based on Host header — no additional IPs needed. The single ingress
controller handles all three environments.

### DNS Setup

ExternalDNS already manages `*.aegisgroup.ch` via RFC2136. Add two wildcard
records for the environment subdomains:

```
*.dev.aegisgroup.ch      A    192.168.48.2
*.staging.aegisgroup.ch  A    192.168.48.2
```

ExternalDNS will create these automatically when HTTPRoutes/Ingresses
reference hostnames in those zones (if the zone is configured). Otherwise,
add static records in BIND.

### TLS Certificates

cert-manager's `vault-issuer` ClusterIssuer already covers `aegisgroup.ch`
and all subdomains (the Vault PKI role allows `allow_subdomains: true`).
No additional issuer configuration needed.

Each environment gets its own TLS certificate:
- `svc-forge.dev.aegisgroup.ch` → cert-manager auto-issues via vault-issuer
- `svc-forge.staging.aegisgroup.ch` → cert-manager auto-issues via vault-issuer
- `svc-forge.aegisgroup.ch` → cert-manager auto-issues via vault-issuer

### Kustomize Overlay Implementation

Each environment's kustomization sets the hostname via patches:

```yaml
# dev/forge/svc-forge/kustomization.yaml
patches:
  - target:
      kind: HTTPRoute
    patch: |
      - op: replace
        path: /spec/hostnames/0
        value: svc-forge.dev.aegisgroup.ch

# staging/forge/svc-forge/kustomization.yaml
patches:
  - target:
      kind: HTTPRoute
    patch: |
      - op: replace
        path: /spec/hostnames/0
        value: svc-forge.staging.aegisgroup.ch

# prod/forge/svc-forge/kustomization.yaml
patches:
  - target:
      kind: HTTPRoute
    patch: |
      - op: replace
        path: /spec/hostnames/0
        value: svc-forge.aegisgroup.ch
```

### Why Same IP, Not Separate IPs

- Traefik already handles multi-tenant routing via Host headers
- Separate IPs would require additional LoadBalancer services (MetalLB/Cilium L2)
- DNS wildcards are simpler with one IP per zone
- Network policies isolate namespaces — ingress sharing is safe
- If isolation is needed later (e.g., dedicated staging cluster), the FQDN
  convention carries over — just change DNS to point to a different IP

### Pipeline Testing with Environment FQDNs

The environment-specific FQDNs enable:

1. **Smoke tests in dev**: CI can `curl svc-forge.dev.aegisgroup.ch/health`
   after deploy to verify the app is running
2. **Integration tests in staging**: Full test suite runs against
   `svc-forge.staging.aegisgroup.ch` with realistic traffic
3. **Canary analysis**: Argo Rollouts AnalysisTemplates query Prometheus
   for success rate on the staging FQDN before promoting to prod
4. **Blue-green verification**: Staging preview URL allows manual QA
   before prod cutover

### Implementation Steps

1. Add DNS wildcard records for `*.dev.aegisgroup.ch` and `*.staging.aegisgroup.ch`
2. Update base microservice template to include HTTPRoute with placeholder hostname
3. Update Kustomize overlays per environment to patch the hostname
4. Update CI templates to include post-deploy smoke test against environment FQDN
5. Update AnalysisTemplate to use environment-specific Prometheus queries
