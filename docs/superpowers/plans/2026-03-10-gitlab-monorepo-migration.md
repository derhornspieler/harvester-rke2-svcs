# GitLab Monorepo Migration + Wiki Sync Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate 14 stale GitLab service repos into one monorepo mirror with bidirectional wiki sync.

**Architecture:** Delete 14 scaffolding repos from GitLab. Create `harvester-rke2-svcs` project on GitLab, push the GitHub monorepo to it. Build a sync script that converts `docs/` subdirectory structure to flat wiki format and back. GitLab CI handles automated sync on push and scheduled polling for wiki edits.

**Tech Stack:** glab CLI, git, bash, GitLab CI, SSH deploy keys

**Spec:** `docs/superpowers/specs/2026-03-10-gitlab-monorepo-migration-design.md`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `fleet-gitops/scripts/sync-wiki.sh` | Bidirectional sync: `docs/` <-> flat wiki format, sidebar generation, link rewriting |
| `.gitlab-ci.yml` | CI pipeline: wiki sync on push + scheduled poll for wiki edits |
| Wiki: `_sidebar.md` | Auto-generated navigation sidebar for GitLab wiki |
| Wiki: `home.md` | Landing page (converted from `docs/README.md`) |

---

## Chunk 1: GitLab Repo Cleanup + Monorepo Creation

### Task 1: Verify all 14 GitLab repos have no unique content

**Files:** None (read-only verification)

- [ ] **Step 1: Run verification script**

For each of the 14 repos, compare commit messages against the GitHub monorepo to confirm no unique work exists. The repos to verify:

```
vault, keycloak, harbor, monitoring, gitlab-platform, fleet-deploy,
external-dns, external-secrets, cert-manager, autoscalers, redis-operator,
cnpg-operator, gateway-api, harvester-rke2-cluster (GitLab copy)
```

Run:
```bash
for repo in vault keycloak harbor monitoring gitlab-platform fleet-deploy \
  external-dns external-secrets cert-manager autoscalers redis-operator \
  cnpg-operator gateway-api; do
  echo "=== $repo ==="
  GIT_SSL_NO_VERIFY=1 glab api \
    "projects/infra_and_platform_services%2F${repo}/repository/commits?per_page=20" \
    2>/dev/null | python3 -c "
import json, sys
commits = json.load(sys.stdin)
for c in commits:
    print(f\"  {c['short_id']} {c['title'][:70]}\")
"
done
```

Expected: All commits match those in the GitHub monorepo `git log`.

- [ ] **Step 2: Record verification result**

If any repo has unique commits not in GitHub, note them and exclude that repo from deletion.

### Task 2: Delete 14 stale GitLab repos

**Files:** None (GitLab API operations)

- [ ] **Step 1: Delete each repo via glab CLI**

```bash
REPOS_TO_DELETE=(
  vault keycloak harbor monitoring gitlab-platform fleet-deploy
  external-dns external-secrets cert-manager autoscalers redis-operator
  cnpg-operator gateway-api
)

for repo in "${REPOS_TO_DELETE[@]}"; do
  echo "Deleting infra_and_platform_services/${repo}..."
  GIT_SSL_NO_VERIFY=1 glab api \
    "projects/infra_and_platform_services%2F${repo}" \
    --method DELETE 2>/dev/null && echo "  Deleted" || echo "  FAILED"
done
```

Note: `harvester-rke2-cluster` on GitLab is a mirror of the GitHub cluster repo — **keep it**.

- [ ] **Step 2: Verify deletion**

```bash
GIT_SSL_NO_VERIFY=1 glab repo list --group infra_and_platform_services
```

Expected: Only `harvester-golden-images` and `harvester-rke2-cluster` remain.

### Task 3: Create `harvester-rke2-svcs` project on GitLab

**Files:** None (GitLab API)

- [ ] **Step 1: Create the project**

```bash
GIT_SSL_NO_VERIFY=1 glab api projects --method POST \
  -f "name=harvester-rke2-svcs" \
  -f "namespace_id=$(GIT_SSL_NO_VERIFY=1 glab api groups/infra_and_platform_services \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')" \
  -f "description=Platform services monorepo — Fleet GitOps, Helm values, manifests, docs" \
  -f "visibility=internal" \
  -f "wiki_enabled=true"
```

- [ ] **Step 2: Add GitLab as a remote and push**

```bash
cd /home/rocky/data/harvester-rke2-svcs
git remote add gitlab git@gitlab.example.com:infra_and_platform_services/harvester-rke2-svcs.git
git push gitlab main --tags
```

- [ ] **Step 3: Verify on GitLab**

```bash
GIT_SSL_NO_VERIFY=1 glab repo view infra_and_platform_services/harvester-rke2-svcs
```

- [ ] **Step 4: Commit**

No code changes — just remote setup.

---

## Chunk 2: Wiki Sync Script

### Task 4: Create the wiki sync script

**Files:**
- Create: `fleet-gitops/scripts/sync-wiki.sh`

- [ ] **Step 1: Write the sync script**

The script handles:
1. `docs-to-wiki` — convert `docs/` tree to flat wiki files
2. `wiki-to-docs` — convert flat wiki files back to `docs/` tree
3. `generate-sidebar` — build `_sidebar.md` from directory listing
4. Link rewriting in both directions

```bash
#!/usr/bin/env bash
# sync-wiki.sh — Bidirectional sync between docs/ and GitLab wiki
#
# Usage:
#   ./sync-wiki.sh docs-to-wiki    # Push docs/ to wiki format (stdout or --output dir)
#   ./sync-wiki.sh wiki-to-docs    # Pull wiki back to docs/ format
#   ./sync-wiki.sh generate-sidebar # Generate _sidebar.md from docs/
set -euo pipefail
```

Key functions:

**docs_to_wiki():**
- Walk `docs/` recursively
- For each `.md` file, compute wiki filename:
  - `docs/architecture/overview.md` -> `architecture-overview.md`
  - `docs/getting-started.md` -> `getting-started.md`
  - `docs/README.md` -> `home.md`
  - `docs/*/index.md` -> `<section>.md` (e.g., `developer-guide.md`)
- Rewrite internal links: `[text](../architecture/overview.md)` -> `[text](architecture-overview)`
- Copy to output directory

**wiki_to_docs():**
- Walk wiki directory
- For each `.md` file, compute docs path:
  - `architecture-overview.md` -> `docs/architecture/overview.md`
  - `getting-started.md` -> `docs/getting-started.md`
  - `home.md` -> `docs/README.md`
  - `developer-guide.md` -> `docs/developer-guide/index.md`
- Reverse link rewriting
- Copy to docs/ tree

**generate_sidebar():**
- Read `docs/` directory structure
- Group files by subdirectory
- Emit `_sidebar.md` with GitLab wiki link format

- [ ] **Step 2: Make executable**

```bash
chmod +x fleet-gitops/scripts/sync-wiki.sh
```

- [ ] **Step 3: Test docs-to-wiki conversion**

```bash
mkdir -p /tmp/wiki-test
./fleet-gitops/scripts/sync-wiki.sh docs-to-wiki --output /tmp/wiki-test
ls /tmp/wiki-test/
# Expect: architecture-overview.md, architecture-pki-certificates.md, etc.
cat /tmp/wiki-test/_sidebar.md
# Expect: structured sidebar with all sections
```

- [ ] **Step 4: Test round-trip**

```bash
mkdir -p /tmp/docs-test
./fleet-gitops/scripts/sync-wiki.sh wiki-to-docs --input /tmp/wiki-test --output /tmp/docs-test
diff -rq docs/ /tmp/docs-test/
# Expect: no meaningful differences (whitespace/link format may differ)
```

- [ ] **Step 5: Commit**

```bash
git add fleet-gitops/scripts/sync-wiki.sh
git commit -m "feat: add bidirectional wiki sync script

Converts docs/ subdirectory structure to flat wiki format and back.
Generates _sidebar.md for GitLab wiki navigation.
Rewrites internal links in both directions.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

### Task 5: Initial wiki push

**Files:** None (wiki git operations)

- [ ] **Step 1: Convert docs to wiki format**

```bash
mkdir -p /tmp/wiki-push
./fleet-gitops/scripts/sync-wiki.sh docs-to-wiki --output /tmp/wiki-push
```

- [ ] **Step 2: Clone the GitLab wiki repo and push content**

```bash
cd /tmp
git clone git@gitlab.example.com:infra_and_platform_services/harvester-rke2-svcs.wiki.git
cd harvester-rke2-svcs.wiki
cp /tmp/wiki-push/*.md .
git add -A
git commit -m "Initial wiki from docs/ directory

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
git push
```

- [ ] **Step 3: Verify wiki renders in GitLab UI**

Navigate to: `https://gitlab.example.com/infra_and_platform_services/harvester-rke2-svcs/-/wikis/home`

Expected: Landing page with sidebar navigation, Mermaid diagrams rendering.

---

## Chunk 3: GitLab CI Sync Pipeline

### Task 6: Create GitLab CI pipeline for wiki sync

**Files:**
- Create: `.gitlab-ci.yml` (wiki sync jobs)

- [ ] **Step 1: Write the CI pipeline**

Two jobs:
1. `sync-docs-to-wiki` — triggers on push to main when `docs/**` changes
2. `sync-wiki-to-docs` — scheduled every 15 min, checks for wiki edits

```yaml
stages:
  - sync

sync-docs-to-wiki:
  stage: sync
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
      changes:
        - docs/**/*
  script:
    - ./fleet-gitops/scripts/sync-wiki.sh docs-to-wiki --output /tmp/wiki-out
    - git clone ${CI_SERVER_URL}/${CI_PROJECT_PATH}.wiki.git /tmp/wiki
    - cp /tmp/wiki-out/*.md /tmp/wiki/
    - cd /tmp/wiki
    - git add -A
    - 'git diff --cached --quiet && echo "No changes" && exit 0'
    - git commit -m "sync: docs/ -> wiki [skip ci]"
    - git push

sync-wiki-to-docs:
  stage: sync
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
  script:
    - git clone ${CI_SERVER_URL}/${CI_PROJECT_PATH}.wiki.git /tmp/wiki
    - ./fleet-gitops/scripts/sync-wiki.sh wiki-to-docs --input /tmp/wiki --output docs/
    - git add docs/
    - 'git diff --cached --quiet && echo "No wiki changes" && exit 0'
    - git checkout -b wiki-sync-$(date +%s)
    - git commit -m "sync: wiki -> docs/"
    - git push -u origin HEAD
    - glab mr create --title "Wiki sync" --description "Automated sync from wiki edits"
```

- [ ] **Step 2: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "ci: add GitLab CI pipeline for bidirectional wiki sync

Syncs docs/ -> wiki on push to main.
Scheduled job syncs wiki edits -> docs/ via MR.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

- [ ] **Step 3: Push to GitLab**

```bash
git push gitlab main
```

- [ ] **Step 4: Create scheduled pipeline in GitLab**

```bash
GIT_SSL_NO_VERIFY=1 glab api \
  "projects/infra_and_platform_services%2Fharvester-rke2-svcs/pipeline_schedules" \
  --method POST \
  -f "description=Wiki sync (wiki -> docs)" \
  -f "ref=main" \
  -f "cron=*/15 * * * *" \
  -f "active=true"
```

### Task 7: Push all changes to both remotes

- [ ] **Step 1: Push to GitHub**

```bash
git push origin main
```

- [ ] **Step 2: Push to GitLab**

```bash
git push gitlab main
```

- [ ] **Step 3: Verify both remotes are in sync**

```bash
git log --oneline -3 origin/main
git log --oneline -3 gitlab/main
```

Expected: Identical commit hashes.
