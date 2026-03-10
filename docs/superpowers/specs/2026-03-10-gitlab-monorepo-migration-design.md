# GitLab Monorepo Migration + Wiki Sync

**Date:** 2026-03-10
**Status:** Approved

## Problem

The GitHub monorepo (`harvester-rke2-svcs`) is the active deployment source, but
16 stale GitLab repos under `infra_and_platform_services` duplicate its content
with no unique work. This split creates confusion about source of truth and
prevents using GitLab's wiki for platform documentation.

## Decision

Consolidate to one monorepo mirrored between GitHub and GitLab. Enable
bidirectional wiki sync between `docs/` and the GitLab wiki.

## Architecture

```
GitHub                                    GitLab
┌────────────────────────┐    mirror     ┌─────────────────────────────────────────────┐
│ derhornspieler/        │◄────────────►│ infra_and_platform_services/                │
│   harvester-rke2-svcs  │              │   harvester-rke2-svcs                       │
│                        │              │     ├── repo (code)                         │
│   .wiki.git (optional) │              │     └── .wiki.git ◄── docs/ bi-sync        │
├────────────────────────┤              ├─────────────────────────────────────────────┤
│ derhornspieler/        │◄────────────►│ infra_and_platform_services/                │
│   harvester-golden-    │    mirror    │   harvester-golden-images                   │
│   images               │              │                                             │
└────────────────────────┘              └─────────────────────────────────────────────┘
```

## Scope

### Phase 1: GitLab Repo Cleanup + Monorepo Mirror

1. Delete 15 stale GitLab service repos (all content exists in GitHub monorepo)
2. Keep `harvester-golden-images` (independent project with active CI)
3. Create `infra_and_platform_services/harvester-rke2-svcs` on GitLab
4. Push GitHub monorepo to the new GitLab project
5. Configure bidirectional mirroring (GitLab pull mirror or dual-remote push)

### Phase 2: Wiki Setup

1. Enable wiki on GitLab `harvester-rke2-svcs` project
2. Create sync script: `docs/` subdirectory structure <-> flat wiki format
3. Generate `_sidebar.md` from docs directory structure
4. Initial push of all docs to GitLab wiki

### Phase 3: Wiki Bidirectional Sync (GitLab CI)

1. GitLab CI pipeline triggered on:
   - Push to `main` (docs/ changes -> wiki)
   - Scheduled job every 15 min (wiki edits -> docs/ MR)
2. Conflict handling: auto-merge if clean, MR with conflicts for human review
3. Credentials: GitLab CI token for wiki, GitHub deploy key for GitHub push

### Out of Scope (for now)

- GitHub Wiki (can add later as a third sync target)
- Per-service wikis on individual repos
- Full monorepo-to-polyrepo migration

## File Mapping (docs/ <-> wiki)

```
docs/architecture/overview.md          -> architecture-overview.md
docs/architecture/pki-certificates.md  -> architecture-pki-certificates.md
docs/developer-guide/quickstart.md     -> developer-guide-quickstart.md
docs/operator-guide/day2-operations.md -> operator-guide-day2-operations.md
docs/getting-started.md                -> getting-started.md
docs/README.md                         -> home.md (wiki landing page)
```

Reverse mapping uses the first hyphen-separated segment as the subdirectory.
Files without a prefix map to `docs/` root.

## Sidebar Generation

Auto-generated `_sidebar.md` from directory structure:

```markdown
**Platform Documentation**

- [Home](home)

**Architecture**
- [Overview](architecture-overview)
- [Authentication & Identity](architecture-authentication-identity)
- [Networking & Ingress](architecture-networking-ingress)
- [PKI & Certificates](architecture-pki-certificates)
- [CI/CD Pipeline](architecture-cicd-pipeline)
- [Observability](architecture-observability-monitoring)
- [Data & Storage](architecture-data-storage)
- [Secrets & Configuration](architecture-secrets-configuration)

**Developer Guide**
- [Getting Started](developer-guide-quickstart)
- [Application Design](developer-guide-application-design)
- [ArgoCD Deployment](developer-guide-argocd-deployment)
- [Fleet Deployment](developer-guide-fleet-deployment)
- [GitLab CI](developer-guide-gitlab-ci)
- [Platform Integration](developer-guide-platform-integration)
- [Troubleshooting](developer-guide-troubleshooting)

**Operator Guide**
- [Bundle Reference](operator-guide-bundle-reference)
- [Day 2 Operations](operator-guide-day2-operations)
- [Fleet Deployment](operator-guide-fleet-deployment)
- [Monitoring & Alerts](operator-guide-monitoring-alerts)
- [Secrets Management](operator-guide-secrets-management)

**Getting Started**
- [Deployment Guide](getting-started)
```

## Mirror Strategy

**Option chosen: GitLab pull mirror + GitHub push**

- GitLab's built-in pull mirroring syncs from GitHub on a schedule
- For pushes from GitLab -> GitHub, a CI job pushes to the GitHub remote
- `harvester-golden-images` uses the same pattern

## Sync Script

New script: `fleet-gitops/scripts/sync-wiki.sh`

Responsibilities:
- Convert `docs/` tree to flat wiki files (prefix subdirectory name)
- Convert flat wiki files back to `docs/` tree
- Generate `_sidebar.md` from directory listing
- Handle internal link rewriting (`[text](../architecture/overview.md)` ->
  `[text](architecture-overview)`)
- Detect changes via git diff, skip no-op syncs

## Credentials Required

| Secret | Purpose | Storage |
|--------|---------|---------|
| GitHub deploy key (read/write) | Push to GitHub repo + wiki | Vault `kv/ci/github-deploy-key` |
| GitLab CI token | Push to GitLab wiki | Built-in `CI_JOB_TOKEN` |

## Repos to Delete

All under `infra_and_platform_services/`:

1. vault
2. keycloak
3. harbor
4. monitoring
5. gitlab-platform
6. fleet-deploy
7. external-dns
8. external-secrets
9. cert-manager
10. autoscalers
11. redis-operator
12. cnpg-operator
13. gateway-api
14. harvester-rke2-cluster (separate from the GitHub cluster repo)

Note: `harvester-rke2-cluster` on GitLab may be a mirror of the GitHub cluster
repo. Verify before deleting — if it has unique CI, keep it.

15. (conditional) harvester-rke2-cluster — verify first

## Risks

- **Accidental deletion**: Verify each repo has no unique commits before delete
- **Mirror lag**: Pull mirrors have ~5 min delay; pushes are immediate
- **Wiki link breakage**: Internal links need rewriting during sync
- **Mermaid rendering**: GitLab renders Mermaid natively; GitHub wiki does not
