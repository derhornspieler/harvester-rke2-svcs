# Platform-Deployments Migration: From ApplicationSets to Centralized GitOps

**From:** Platform Team
**To:** Forge Team, Identity-UI Team
**Date:** March 16, 2026
**Status:** Planning phase — full rollout in Q2 2026

---

## TL;DR

We're migrating to a **centralized GitOps repository** (`platform/platform-deployments`) where all application deployments live. This is the industry standard used by Intuit, Spotify, and Netflix.

**What changes for you:**
- Update your CI/CD deploy stage to push image tags to the central repo (instead of managing ArgoCD ApplicationSets)
- One small YAML change per environment (dev, staging, prod)
- No changes to your build pipelines, Dockerfile, image scanning, or team structure

**What stays the same:**
- You build images in your own repos (forge, identity-ui)
- You own your own code and deployment logic
- Fewer tokens to manage, clearer promotion path

**You can start migrating at your own pace.** Old ApplicationSets remain active during the transition period.

---

## The Big Picture: Why We're Doing This

Currently, each team manages their own ArgoCD ApplicationSets scattered across different GitLab repos. This works, but creates friction:

- **ArgoCD config sprawl** — Multiple teams, multiple repos, hard to find who owns what
- **Token proliferation** — Every team needs separate ArgoCD PATs and service accounts
- **Inconsistent promotion** — No clear path from dev → staging → production
- **Scaling pain** — Adding a 3rd or 4th team multiplies the complexity

**The solution:** A single, centralized `platform/platform-deployments` repository that holds all Kustomize overlays for all applications, across all environments. ArgoCD watches only this one repo.

This is **not** a constraint—it's a clarity upgrade. Your code still lives in your own repos. You still own your deployment logic. But the "what's deployed where" question has one authoritative answer.

---

## How It Works: The New Flow

### Step 1: You Build Your Image (No Change)

```bash
# In your repo (forge/svc-forge, identity-ui, etc.)
$ docker build -t harbor.dev.example.com/forge/svc-forge:abc1234 .
$ docker push harbor.dev.example.com/forge/svc-forge:abc1234
```

### Step 2: Update the Image Tag (New Deploy Stage)

Your CI/CD pipeline's **deploy stage** now updates a YAML file in `platform-deployments`:

```yaml
deploy-dev:
  stage: deploy
  image: docker.io/alpine/k8s:1.32.4
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
  script:
    - |
      # Clone the central deployments repo
      git clone https://${CI_JOB_TOKEN_USER}:${CI_JOB_TOKEN}@gitlab.example.com/platform/platform-deployments.git
      cd platform-deployments

      # Update the image tag in your app's kustomization
      cd dev/forge/svc-forge
      kustomize edit set image CHANGEME_IMAGE=harbor.dev.example.com/forge/svc-forge:${CI_COMMIT_SHORT_SHA}

      # Commit and push
      git add .
      git commit -m "deploy: svc-forge ${CI_COMMIT_SHORT_SHA} to dev"
      git push origin main

      # ✅ ArgoCD auto-syncs to dev within ~3 minutes
```

### Step 3: ArgoCD Auto-Syncs (Already Happens)

When you push the image tag update to `platform-deployments`, ArgoCD sees the change and automatically deploys:

- **Dev environment** → Auto-syncs immediately (self-service)
- **Staging environment** → Auto-syncs after MR approval (team lead review)
- **Production environment** → Manual sync or platform team approval (safety gate)

---

## What Changes for Your Team

### 1. Create Your App Structure in `platform-deployments`

Platform team will seed the initial structure. You'll have folders like:

```
platform-deployments/
  base/
    forge/svc-forge/            # Base manifest shared across all envs
      kustomization.yaml
      deployment.yaml
      service.yaml
    forge/svc-milvus/
      kustomization.yaml
      ...
    identity/identity-webui/
      kustomization.yaml
      ...

  dev/
    forge/svc-forge/            # Dev overlay
      kustomization.yaml        # Sets image tag, replicas, etc.
    identity/identity-webui/
      kustomization.yaml

  staging/
    forge/svc-forge/
      kustomization.yaml
    identity/identity-webui/
      kustomization.yaml

  prod/
    forge/svc-forge/
      kustomization.yaml
    identity/identity-webui/
      kustomization.yaml
```

### 2. Update Your CI Deploy Stage

Add or modify your `.gitlab-ci.yml`:

```yaml
# For Forge team (svc-forge)
deploy-dev:
  stage: deploy
  image: docker.io/alpine/k8s:1.32.4
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
  script:
    - apk add --no-cache git curl
    - git clone https://${CI_JOB_TOKEN_USER}:${CI_JOB_TOKEN}@gitlab.example.com/platform/platform-deployments.git
    - cd platform-deployments
    - cd dev/forge/svc-forge
    - kustomize edit set image CHANGEME_IMAGE=harbor.dev.example.com/forge/svc-forge:${CI_COMMIT_SHORT_SHA}
    - git add . && git commit -m "deploy: svc-forge ${CI_COMMIT_SHORT_SHA} to dev" && git push origin main

deploy-staging:
  stage: deploy
  image: docker.io/alpine/k8s:1.32.4
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
  script:
    - apk add --no-cache git
    - git clone https://${CI_JOB_TOKEN_USER}:${CI_JOB_TOKEN}@gitlab.example.com/platform/platform-deployments.git
    - cd platform-deployments
    - cd staging/forge/svc-forge
    - kustomize edit set image CHANGEME_IMAGE=harbor.dev.example.com/forge/svc-forge:${CI_COMMIT_SHORT_SHA}
    - git add . && git commit -m "deploy: svc-forge ${CI_COMMIT_SHORT_SHA} to staging" && git push origin main
  # ℹ️ MR step (optional, for extra safety): create MR instead of direct push
  #   Requires team+lead approval via CODEOWNERS
```

### 3. Promote to Production (When Ready)

For production, you create an MR to update the prod overlay. Platform team reviews and merges.

Or, if your team has deployment authority, you push directly to `prod/` folder (CODEOWNERS gates it).

---

## What Does NOT Change

✅ **Your source code repos** — forge/svc-forge, identity-ui, etc. stay where they are
✅ **Your build pipeline** — Docker build, image scanning, artifact registry all unchanged
✅ **Your git workflows** — Same branching strategy, same code review process
✅ **Your team structure** — No reorganization, no group changes
✅ **Your credentials** — CI JOB_TOKEN already works; no new secrets needed

---

## Environment Promotion Path

```
┌─────────────────────────────────────────────────────────────────┐
│  Your Repo (forge/svc-forge)                                    │
│  $ git push origin main                                         │
│  → CI builds, scans, pushes image to Harbor                    │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  Dev Deploy (Auto-Sync)                                         │
│  Deploy stage: git push origin main (platform-deployments)     │
│  → ArgoCD auto-syncs to dev-forge namespace                    │
│  ✅ Immediate feedback, catch issues early                     │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  Staging Deploy (MR + Team Approval)                            │
│  Deploy stage: git push origin main (or create MR)             │
│  → CODEOWNERS: team + engineering lead approval                │
│  → After merge: ArgoCD auto-syncs to staging-forge namespace  │
│  ✅ Gated promotion, final QA check                           │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  Production Deploy (Manual Sync or Platform Approval)           │
│  Create MR to prod/ folder                                      │
│  → CODEOWNERS: platform team approval                           │
│  → After merge: Manual trigger or auto-sync (TBD)              │
│  → ArgoCD syncs to app-forge namespace                         │
│  ✅ Highest safety gate, audit trail in git                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Adding a New Application

1. **Create the folder structure in `platform-deployments`:**
   ```bash
   mkdir -p base/forge/svc-new-app
   mkdir -p dev/forge/svc-new-app
   mkdir -p staging/forge/svc-new-app
   mkdir -p prod/forge/svc-new-app
   ```

2. **Add Kustomize overlays** (platform team provides a template):
   ```yaml
   # base/forge/svc-new-app/kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization

   resources:
     - deployment.yaml
     - service.yaml

   # dev/forge/svc-new-app/kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization

   bases:
     - ../../base/forge/svc-new-app

   images:
   - name: CHANGEME_IMAGE
     newName: harbor.dev.example.com/forge/svc-new-app
     newTag: latest
   ```

3. **Submit MR to `platform-deployments`** — platform team reviews and merges

4. **Update your `.gitlab-ci.yml`** with the deploy stage above

5. **Push to main branch** — ArgoCD auto-discovers the new folder and creates an Application

Done! ArgoCD will watch your new app folder and auto-sync within 3 minutes.

---

## Token & Authentication Changes (You Don't Need to Do Anything)

**Behind the scenes, the platform team is:**

| Change | Old Way | New Way | Impact |
|--------|---------|---------|--------|
| **ArgoCD auth** | Individual PATs per team | Single Group Deploy Token (GDT) | ✅ Never expires, no renewal needed |
| **CI access to platform-deployments** | New service account + token | Existing CI JOB_TOKEN | ✅ No new secrets, no new Vault entries |
| **SCM provider** | Per-team SCM Provider + GAT | Git directory generator | ✅ Simpler, fewer moving parts |

**For your team:** Use your existing CI JOB_TOKEN in the deploy stage. No action needed.

---

## Migration Timeline

| Phase | When | What Happens |
|-------|------|--------------|
| **Infrastructure** | Week of Mar 17 | Platform team deploys platform-deployments repo + ArgoCD configuration |
| **Seed & Validate** | Week of Mar 24 | Initial structure seeded for forge & identity-ui; platform team validates |
| **Forge Migration** | Week of Mar 31 (TBD) | Forge team updates CI deploy stages; old ApplicationSet marked deprecated |
| **Identity-UI Migration** | Week of Apr 7 (TBD) | Identity-UI team updates CI deploy stages; old Application marked deprecated |
| **Cleanup** | Late April | Remove old ApplicationSets once all teams migrated |

**You decide your migration date.** Old ApplicationSets remain active. There's no hard deadline—migrate when it's convenient for your team.

---

## FAQ

### Q: Do I need to change my git remote or clone a different repo?

**A:** No. Your source repo (forge/svc-forge) stays the same. You'll clone `platform-deployments` only in your **deploy stage**, not your primary workflow.

### Q: What if I need to roll back?

**A:** Revert the commit in `platform-deployments` that changed your image tag, or manually trigger ArgoCD to sync to the previous commit. Git history is your audit trail.

### Q: Can I deploy directly to staging/prod, or must I go through dev?

**A:** You can deploy to staging/dev simultaneously (via multi-stage pipeline). Prod always requires an MR + approval. This is configurable—talk to platform team if your workflow needs adjustment.

### Q: What if platform-deployments gets too big?

**A:** We can split into multiple repos later (platform-deployments-forge, platform-deployments-identity, etc.). But start with one central repo to establish the pattern.

### Q: Do I lose control over my deployment config?

**A:** No. You own the Kustomize overlays for your app. You decide what goes in `base/`, `dev/`, `staging/`, and `prod/`. Platform team reviews structure, but you control the manifests.

### Q: Who can commit to platform-deployments?

**A:** Dev env: your team (CODEOWNERS: `dev/*/`). Staging: your team + engineering lead. Prod: platform team. But if your team has a lead, they can approve staging merges.

### Q: Can multiple teams deploy to the same namespace?

**A:** Not recommended. Each app gets its own namespace (`dev-forge`, `dev-identity`, etc.). Shared namespaces (shared services) are managed by platform team in a separate path.

---

## Support & Questions

**Platform-deployments repository:**
- Will include a comprehensive README with examples for every scenario
- Base templates and Kustomize overlays pre-seeded
- Example CI/CD pipelines for reference

**Get help:**
- Slack channel: `#platform-team`
- Schedule a sync with platform team for questions about your specific app
- Check the platform-deployments README first—most answers are there

---

## What's Next

1. **Platform team:** Deploy infrastructure and seed initial structure (week of Mar 17)
2. **Your team:** Review this document and the platform-deployments README
3. **When ready:** Update your `.gitlab-ci.yml` with the new deploy stage (takes ~30 min)
4. **Test:** Push to main, watch ArgoCD sync to dev environment
5. **Promote:** Create MRs for staging and prod when ready

**Questions?** Reach out to the platform team on Slack. We're here to help make this transition smooth.

---

**Platform Team**
March 16, 2026
