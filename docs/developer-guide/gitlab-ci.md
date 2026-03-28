# GitLab CI/CD Developer Guide

## Overview

All CI/CD pipelines authenticate to Harbor and Vault automatically using
GitLab's JWT tokens. **No CI/CD variables need to be configured** — credentials
are fetched from Vault at runtime.

## Prerequisites

Before your pipeline can build and push images:

1. **`DOMAIN` CI variable must be set** — The platform team sets this as a
   group-level CI variable on each GitLab group. It provides the base domain
   for Vault, Harbor, and other service URLs. Verify it exists:
   GitLab → Group → Settings → CI/CD → Variables → `DOMAIN`

2. **Create your Harbor project** — Log in to Harbor (`harbor.dev.<DOMAIN>`)
   via Keycloak and create a project matching your GitLab group name.
   The platform robot account (`robot$ci-push`) has system-level push/pull access
   to all projects automatically.

3. **Your `.gitlab-ci.yml` includes the platform templates** — these handle
   Vault authentication, Harbor login, image building, scanning, and deployment.

### Group-Level CI Variables (set by platform team)

| Variable | Example | Purpose |
|----------|---------|---------|
| `DOMAIN` | `example.com` | Base domain for all services (Vault, Harbor, etc.) |

These are inherited by all projects within the group. Developers do not
need to set any project-level variables for basic CI/CD functionality.

## Quick Start

Minimal `.gitlab-ci.yml` for a microservice with full CI/CD pipeline:

```yaml
include:
  - component: gitlab.example.com/infra_and_platform_services/ci-components/build@1.0.0
    inputs:
      image_name: <TEAM>/<APP>

  - component: gitlab.example.com/infra_and_platform_services/ci-components/scan@1.0.0

  - component: gitlab.example.com/infra_and_platform_services/ci-components/deploy@1.0.0
    inputs:
      team: <TEAM>
      app: <APP>
```

This gives you: secret detection, image build, vulnerability scan, SAST, and automated
deployment to dev. ArgoCD syncs within ~3 minutes.

All authentication (Vault JWT, Harbor push, SSH deploy key) is handled by the components
automatically — no CI variables needed.

Browse available components at: `https://gitlab.example.com/explore/catalog`

## How Authentication Works

```
┌─────────────┐     JWT token      ┌───────────┐    read secret    ┌───────────┐
│  GitLab CI  │ ──────────────────► │   Vault   │ ◄──────────────── │  Harbor   │
│  Job Pod    │                     │  JWT auth  │                   │  ci-robot │
│             │ ◄────────────────── │           │                   │           │
│             │  robot$ci-push      │           │                   │           │
│             │  credentials        │ kv/services│                   │           │
│             │                     │ /harbor/   │                   │           │
│             │ ──push image──────────────────────────────────────► │           │
└─────────────┘                     └───────────┘                   └───────────┘
```

1. Each job declares an `id_tokens` block with `VAULT_ID_TOKEN` (audience = GitLab URL)
2. The job authenticates to Vault using `auth/jwt/login` with the token
3. The job reads Harbor robot credentials from `kv/services/harbor/ci-robot`
4. The job uses `robot$ci-push` to push/pull images to/from Harbor

**Important:** Every job that needs Vault access must declare `id_tokens`:

```yaml
my-job:
  id_tokens:
    VAULT_ID_TOKEN:
      aud: https://gitlab.<DOMAIN>
```

**No group-level or project-level CI variables are needed for Harbor access.**

## Pipeline Patterns

### Microservice Pattern

Full build → scan → deploy to platform-deployments pipeline using CI Catalog components:

```yaml
include:
  - component: gitlab.example.com/infra_and_platform_services/ci-components/lint@1.0.0
    inputs:
      hadolint_enabled: true

  - component: gitlab.example.com/infra_and_platform_services/ci-components/build@1.0.0
    inputs:
      image_name: <TEAM>/<APP>

  - component: gitlab.example.com/infra_and_platform_services/ci-components/scan@1.0.0
    inputs:
      image_name: harbor.dev.example.com/<TEAM>/<APP>:$CI_COMMIT_SHORT_SHA

  - component: gitlab.example.com/infra_and_platform_services/ci-components/deploy@1.0.0
    inputs:
      team: <TEAM>
      app: <APP>
```

**Stages:** lint → build → scan → deploy

Each component handles its own Vault authentication and credentials.
Your app must exist in `platform-deployments/dev/<TEAM>/<APP>/` for deployment to work.

### Platform Service Pattern

Platform services (deployed via harvester-rke2-svcs Fleet GitOps) use lint and scan
components only — they are deployed by the platform team using Fleet, not platform-deployments:

```yaml
include:
  - component: gitlab.example.com/infra_and_platform_services/ci-components/lint@1.0.0
    inputs:
      shellcheck_paths: scripts/ fleet-gitops/

  - component: gitlab.example.com/infra_and_platform_services/ci-components/scan@1.0.0
```

**Note:** Platform services do not use the deploy component. Deployment is managed
by Fleet GitOps (`deploy.sh`). Use this pattern only if you are a platform operator.

## Available Job Templates

### Build

| Template | Image | Description |
|----------|-------|-------------|
| `.build:kaniko` | kaniko v1.23.2 | Build and push container images using Kaniko |

Harbor credentials are fetched from Vault automatically. The Vault root CA
is mounted at `/etc/ssl/certs/vault-root-ca.pem` for TLS trust.

### Scan

| Template | Image | Description |
|----------|-------|-------------|
| `.scan:gitleaks` | gitleaks v8.30 | Secret detection in source code |
| `.scan:semgrep` | semgrep v1.153 | SAST scanning |
| `.scan:trivy-fs` | trivy v0.69 | Filesystem vulnerability scan |
| `.scan:trivy-image` | trivy v0.69 | Container image vulnerability scan |
| `.scan:sbom` | syft v1.38 | Generate SPDX SBOM |
| `.scan:license` | trivy v0.69 | License compliance check |

### Deploy to platform-deployments

The `.deploy:platform-deployments` template updates image tags in the centralized
deployment repository. This is the standard pattern for all application deployments.

| Template | Description |
|----------|-------------|
| `.deploy:platform-deployments` | Update image tag and push to platform-deployments |

### Vault Authentication

| Template | Description |
|----------|-------------|
| `.vault_jwt_auth` | Authenticate to Vault, sets `VAULT_TOKEN` |
| `.harbor_auth` | Fetch Harbor robot credentials from Vault |

Use `.vault_jwt_auth` in custom jobs that need Vault access:

```yaml
my-custom-job:
  extends: .vault_jwt_auth
  id_tokens:
    VAULT_ID_TOKEN:
      aud: https://gitlab.${DOMAIN}
  script:
    - vault kv get kv/services/ci/my-secret
```

Use `.harbor_auth` when you need Harbor credentials in a custom job
that has `curl` available:

```yaml
my-harbor-job:
  extends: .harbor_auth
  script:
    - echo "User: ${HARBOR_CI_USER}"
    - buildah login -u "${HARBOR_CI_USER}" -p "${HARBOR_CI_PASSWORD}" "${HARBOR_REGISTRY}"
```

## Vault Secrets in CI

CI jobs can read any secret under `kv/services/ci/*` using the `gitlab-ci`
JWT role. For protected branches (main/master), use `gitlab-ci-protected`.

```yaml
read-secret:
  <<: *vault_jwt_auth
  id_tokens:
    VAULT_ID_TOKEN:
      aud: https://gitlab.${DOMAIN}
  variables:
    VAULT_ROLE: gitlab-ci-protected   # Only works on protected branches
  script:
    - MY_SECRET=$(vault kv get -field=password kv/services/ci/my-app)
```

## Deploying to platform-deployments

After building and scanning your image, the deploy stage updates the image tag in the `platform-deployments` repository. ArgoCD automatically syncs the updated manifests to the cluster.

### Deploy Stage Pattern

Use the deploy CI Catalog component. Include it once with your team/app settings:

**For development (auto-push to dev branch):**

```yaml
include:
  - component: gitlab.example.com/infra_and_platform_services/ci-components/deploy@1.0.0
    inputs:
      team: <TEAM>
      app: <APP>
```

This creates a `deploy:dev` job that auto-pushes image tags to the `dev` branch
of `platform-deployments` on every merge to `main`.

**For staged/prod promotion (manual MR):**

The deploy component also provides manual promotion jobs. To add them, include
the legacy templates alongside the catalog component:

```yaml
include:
  - component: gitlab.example.com/infra_and_platform_services/ci-components/deploy@1.0.0
    inputs:
      team: <TEAM>
      app: <APP>
  - project: 'infra_and_platform_services/harvester-rke2-svcs'
    ref: main
    file: '/services/gitlab/ci-templates/jobs/deploy.yml'

promote:staged:
  extends: .deploy:promote-staged
  variables:
    DEPLOY_TEAM: <TEAM>
    DEPLOY_APP: <APP>

promote:prod:
  extends: .deploy:promote-prod
  variables:
    DEPLOY_TEAM: <TEAM>
    DEPLOY_APP: <APP>
```

Promotion jobs create a branch and print a link to create an MR in GitLab.

### What the Deploy Stage Does

The template automatically:

1. Authenticates to Vault and fetches the SSH deploy key from `kv/services/ci/platform-deploy-key`
2. Configures SSH and clones `platform-deployments` via SSH (`git@gitlab.<DOMAIN>:platform/platform-deployments.git`)
3. Updates the image tag in the overlay's `kustomization.yaml`:
   ```bash
   cd ${DEPLOY_ENV}/${DEPLOY_TEAM}/${DEPLOY_APP}
   kustomize edit set image CHANGEME_IMAGE=harbor.dev.<DOMAIN>/${DEPLOY_TEAM}/${DEPLOY_APP}:${CI_COMMIT_SHORT_SHA}
   ```
4. Commits the change with message: `deploy: <app> <tag> to <env>`
5. Pushes to the target branch (dev = direct push, staging/prod = MR)

**Why SSH?** Deploy keys never expire, are scoped to a single project, and
don't require token rotation. The private key is stored in Vault and fetched
by CI pipelines at runtime.

The SSH deploy key is owned by the `gitlab-ci` service account (a Keycloak
user with Developer access on the `platform` group). Keys are provided via
`.env` and uploaded to GitLab by the `gitlab-admin-setup` Job.

### ArgoCD Auto-Sync Timeline

- **dev**: Syncs immediately within ~3 minutes (auto-sync enabled)
- **staging**: Syncs after MR is merged (auto-sync enabled post-merge)
- **prod**: Manual sync via ArgoCD UI or `argocd app sync` command

### Adding Your App to platform-deployments

Before you can deploy, your app's overlay must exist in `platform-deployments`:

```bash
platform-deployments/
  dev/<TEAM>/<APP>/
    kustomization.yaml               # Kustomize overlay with image tag
    deployment.yaml                   # Your Deployment, Service, etc.
  staged/<TEAM>/<APP>/
    kustomization.yaml
    deployment.yaml
  prod/<TEAM>/<APP>/
    kustomization.yaml
    deployment.yaml
```

Each team owns their overlay structure — define your own Deployment, Service,
Ingress, HPA, etc. directly in the overlay. No shared base required.

To add your app:

1. Create your overlay folders in `platform-deployments` (e.g., `dev/<TEAM>/<APP>/`)
2. Define your Kubernetes manifests and `kustomization.yaml`
3. Submit MR for platform team review
4. Once merged, your CI/CD deploy stage can update image tags

See the [ArgoCD Deployment Patterns](argocd-deployment.md#adding-a-new-application) guide for detailed steps.

## Private CA Trust

All CI job pods mount the platform root CA at `/etc/ssl/certs/vault-root-ca.pem`.
The runner's `pre_build_script` automatically installs it into the system
trust store if `update-ca-certificates` is available in the job image.

For images without `update-ca-certificates`, reference the CA file directly:

```yaml
# Kaniko
--registry-certificate "${HARBOR_REGISTRY}=/etc/ssl/certs/vault-root-ca.pem"

# curl
curl --cacert /etc/ssl/certs/vault-root-ca.pem https://internal-service/

# wget
wget --ca-certificate=/etc/ssl/certs/vault-root-ca.pem https://internal-service/
```

## Troubleshooting

### Deploy stage fails with "git clone failed"

- Verify your app folders exist in `platform-deployments`: `dev/<team>/<app>/`, `staging/<team>/<app>/`, etc.
- Check that the SSH deploy key is in Vault: `vault kv get kv/services/ci/platform-deploy-key`
- Verify the GitLab CI JOB_TOKEN has access to the `platform-deployments` repo (usually inherited from the platform group)

### "kustomize edit set image" command fails

- Ensure `kustomization.yaml` exists in the overlay folder
- Verify the `CHANGEME_IMAGE` entry exists in the `images:` section
- Example valid entry:
  ```yaml
  images:
    - name: CHANGEME_IMAGE
      newName: harbor.dev.<DOMAIN>/<TEAM>/<APP>
      newTag: latest
  ```

### Image tag updated but ArgoCD didn't sync

- ArgoCD checks for changes every ~3 minutes (configurable)
- Check ArgoCD logs: `kubectl logs -n argocd deployment/argocd-application-controller`
- Manually trigger sync: `argocd app sync <APP>-dev`
- Verify the git push was successful: `git log` in platform-deployments should show your commit

### "invalid username/password" on Harbor login

- Verify your project exists in Harbor — log in via Keycloak and create it
- Check Vault has robot credentials: the platform deploys `robot$ci-push` automatically
- The `$` in `robot$ci-push` must be escaped in shell scripts (`robot\$ci-push`)

### "Vault JWT auth failed" / "permission denied" / "missing token"

- **Must use `id_tokens`** — `CI_JOB_JWT_V2` is removed in GitLab 17+. Add `id_tokens:` block to your job
- The `aud` must match the GitLab URL: `aud: https://gitlab.<DOMAIN>`
- The token variable name must be `VAULT_ID_TOKEN` (matching the CI templates)
- Auth path is `auth/jwt/login` (not `auth/jwt/gitlab/login`)
- Check the `vault-jwt-auth-setup` Job completed: `kubectl get job vault-jwt-auth-setup -n gitlab`

### "Failed to get Harbor creds from Vault"

- Check `kv/services/harbor/ci-robot` exists in Vault
- Check the `harbor-oidc-setup` Job completed: `kubectl get job harbor-oidc-setup -n harbor`
- The Vault `gitlab-ci-read` policy must include `kv/data/services/harbor/ci-robot`

### Build cache misses

Kaniko uses `${HARBOR_REGISTRY}/ci-cache/${CI_PROJECT_NAME}` for layer caching.
The `ci-cache` project must exist in Harbor. Create it via Harbor UI if needed.

## Pipeline Efficiency

Techniques to reduce build times and avoid unnecessary work.

### Skip Builds When Source Hasn't Changed

Use `changes:` rules to only run jobs when relevant files are modified.
This avoids rebuilding images when only docs or tests change:

```yaml
build:backend:
  stage: build
  script:
    - buildah bud --layers -t "${IMAGE}:${CI_COMMIT_SHORT_SHA}" .
    - buildah push "${IMAGE}:${CI_COMMIT_SHORT_SHA}"
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
      changes:
        - "**/*.go"
        - go.mod
        - go.sum
        - Dockerfile
        - .dockerignore

lint:frontend:
  stage: lint
  script:
    - cd frontend && npm ci && npx eslint .
  rules:
    - changes:
        - "frontend/**"
```

This pattern is used by identity-portal to skip backend builds when only
frontend files change (and vice versa).

### Docker Layer Caching

Use `--layers` with Buildah or `--cache=true` with Kaniko to reuse
previously built layers:

```yaml
# Buildah (recommended)
buildah bud --layers \
  -f Dockerfile \
  -t "${IMAGE}:${CI_COMMIT_SHORT_SHA}" \
  -t "${IMAGE}:${CI_COMMIT_REF_SLUG}" \
  .

# Kaniko (alternative — stores cache in Harbor)
/kaniko/executor \
  --cache=true \
  --cache-repo="${HARBOR_REGISTRY}/ci-cache/${CI_PROJECT_NAME}" \
  --snapshot-mode=redo
```

For Kaniko caching, the `ci-cache` project must exist in Harbor.
Create it via the Harbor UI if needed.

### Dual-Tag Images

Tag images with both the commit SHA and branch name. The SHA is immutable
(used for deployments), the branch tag is mutable (useful for dev testing):

```yaml
- buildah push "${IMAGE}:${CI_COMMIT_SHORT_SHA}"
- buildah push "${IMAGE}:${CI_COMMIT_REF_SLUG}"
```

### Promote Images Without Rebuilding

Use `crane tag` to add production tags to an existing image digest.
No rebuild needed — the same bytes are served under a new tag:

```yaml
promote:production:
  stage: deploy-production
  image: gcr.io/go-containerregistry/crane:latest
  script:
    - crane auth login "${REGISTRY}" -u "${HARBOR_USER}" -p "${HARBOR_PASS}"
    - crane tag "${IMAGE}:${CI_COMMIT_SHORT_SHA}" "production"
    - crane tag "${IMAGE}:${CI_COMMIT_SHORT_SHA}" "v${CI_PIPELINE_IID}"
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
      when: manual
```

### Skip Deploy When Tag Is Current

The deploy template already checks if the image tag has changed before
committing. If the tag in `platform-deployments` is already up to date,
it skips the push:

```yaml
git add .
if git diff --cached --quiet; then
  echo "No changes — image tag already up to date"
else
  git commit -m "deploy: <APP> ${CI_COMMIT_SHORT_SHA} to dev"
  git push origin dev
fi
```

This prevents empty commits and unnecessary ArgoCD reconciliation.

### Dependency Caching

Cache package manager artifacts between pipeline runs:

```yaml
# Go modules
cache:
  key: go-${CI_PROJECT_PATH_SLUG}
  paths:
    - .go/pkg/mod/
  policy: pull-push

# Node.js
cache:
  key: node-${CI_PROJECT_PATH_SLUG}
  paths:
    - .npm/
  policy: pull-push

# Python
cache:
  key: pip-${CI_PROJECT_PATH_SLUG}
  paths:
    - .pip-cache/
  policy: pull-push
```

Use `policy: pull-push` to read cache from previous builds and update
it with new dependencies.

## Platform Deployment Pipeline (for platform operators)

This section is for **platform operators managing the harvester-rke2-svcs repository**. Application developers should use the patterns in [Deploying to platform-deployments](#deploying-to-platform-deployments) above.

The `harvester-rke2-svcs` repository has its own GitLab CI pipeline for deploying
platform services (Vault, Keycloak, GitLab, Prometheus, Harbor, ArgoCD) via Fleet GitOps.

### Pipeline Stages

| Stage | Trigger | What it does |
|-------|---------|-------------|
| `lint` | MR + main | yamllint, shellcheck on fleet-gitops scripts |
| `validate` | MR only | Template rendering dry-run (catches variable errors) |
| `build` | main only | Computes next BUNDLE_VERSION from `bundle-v*` git tags |
| `push` | main only | Pushes Helm charts and Fleet bundles to Harbor OCI registry |
| `deploy` | **manual** | Creates Fleet HelmOps on Rancher management cluster |
| `post-deploy` | **manual** | Re-runs post-deploy checks (fallback if deploy's post-deploy phase needs retry) |
| `sync` | main only | Sanitized push to GitHub mirror |
| `rotate` | scheduled | Rancher API token rotation (every 60 days) |

### Credential Flow

All credentials are fetched from Vault via JWT auth at runtime. The pipeline uses
the `gitlab-ci-fleet-deploy` Vault role, which is bound to this specific project
on protected branches only.

```
GitLab CI Job → JWT id_token → Vault auth/jwt/login → Vault token
  → Read kv/services/ci/fleet-deploy → RANCHER_URL, RANCHER_TOKEN, HARBOR_USER, HARBOR_PASS
  → Build .env from .env.ci + Vault secrets
  → Run deploy scripts
```

No GitLab CI variables are needed for deployment (the group-level `DOMAIN` variable
is the only CI variable used).

### Making Platform Changes

```bash
# 1. Create feature branch
git checkout -b feat/update-monitoring

# 2. Edit templates/values
vim fleet-gitops/20-monitoring/prometheus-stack/values.yaml

# 3. Push and create MR — lint + validate run automatically
git push -u origin feat/update-monitoring
glab mr create --title "Update Prometheus stack" --target-branch main

# 4. Merge — CI auto-pushes charts/bundles to Harbor, creates git tag
glab mr merge

# 5. Deploy — click the manual deploy-fleet job in GitLab CI
# Or deploy from workstation: cd fleet-gitops/scripts && ./deploy.sh
```

### Phase 5: CSR Signing (First Deploy Only)

The Vault intermediate CA CSR signing requires the offline Root CA key and must
run from a workstation:

```bash
cd fleet-gitops
./scripts/sign-csr-only.sh
```

This is only needed once per cluster lifecycle (intermediate CA has 15-year validity).
Subsequent deploys skip this step automatically.

### CI Tools Image

The pipeline uses `harbor.dev.<DOMAIN>/library/fleet-deploy-tools:v1.0.0`.
To rebuild:

```bash
cd fleet-gitops/ci
docker build -t harbor.dev.<DOMAIN>/library/fleet-deploy-tools:v1.0.0 -f Dockerfile.tools .
docker push harbor.dev.<DOMAIN>/library/fleet-deploy-tools:v1.0.0
```

### Rancher Token Rotation

A GitLab scheduled pipeline runs every 60 days with `ROTATION_JOB=rancher-token`.
It creates a new 90-day Rancher API token, updates Vault and the cluster-autoscaler
secret, then deletes the old token. No manual intervention needed.

## Reference

- [ArgoCD Deployment Patterns](argocd-deployment.md) — centralized GitOps platform-deployments model
- [CI/CD Pipeline Architecture](../architecture/cicd-pipeline.md) — system design
- [Secrets & Configuration](../architecture/secrets-configuration.md) — Vault paths
- [platform-deployments Repository](../../examples/platform-deployments/) — repository structure and conventions
- [2026-03-16 Platform Deployments Migration](../../fleet-gitops/scripts/docs/communications/2026-03-16-platform-deployments-migration.md) — detailed migration guide
- [Getting Started — Deployment section](../getting-started.md) — general deployment workflow
