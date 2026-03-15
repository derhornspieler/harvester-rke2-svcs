# GitLab CI/CD Developer Guide

## Overview

All CI/CD pipelines authenticate to Harbor and Vault automatically using
GitLab's JWT tokens. **No CI/CD variables need to be configured** — credentials
are fetched from Vault at runtime.

## Prerequisites

Before your pipeline can build and push images:

1. **Create your Harbor project** — Log in to [Harbor](https://harbor.dev.example.com)
   via Keycloak and create a project matching your GitLab namespace (e.g., `forge`).
   The platform robot account (`robot$ci-push`) has system-level push/pull access
   to all projects automatically.

2. **Your `.gitlab-ci.yml` includes the platform templates** — these handle
   Vault authentication, Harbor login, image building, scanning, and deployment.

## Quick Start

Minimal `.gitlab-ci.yml` for a microservice:

```yaml
include:
  - project: 'infra_and_platform_services/gitlab-ci-templates'
    file:
      - '/stages.yml'
      - '/patterns/microservice.yml'

variables:
  APP_NAME: my-service
```

This gives you: secret detection, linting, build, image scan, SBOM, and deploy.

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

1. GitLab injects `CI_JOB_JWT_V2` into every CI job automatically
2. The job authenticates to Vault using `auth/jwt/gitlab/login`
3. The job reads Harbor robot credentials from `kv/services/harbor/ci-robot`
4. The job uses `robot$ci-push` to push/pull images to/from Harbor

**No group-level or project-level CI variables are needed for Harbor access.**

## Pipeline Patterns

### Microservice Pattern

Full build → test → scan → deploy pipeline:

```yaml
include:
  - project: 'infra_and_platform_services/gitlab-ci-templates'
    file:
      - '/stages.yml'
      - '/patterns/microservice.yml'

variables:
  APP_NAME: my-service             # ArgoCD application name
  HARBOR_PROJECT: forge            # Harbor project (must exist)
```

**Stages:** secret-detection → hadolint → build → image-scan → sbom → deploy-staging → promote-production

### Platform Service Pattern

For GitOps-managed platform services with ESO and Blue/Green rollouts:

```yaml
include:
  - project: 'infra_and_platform_services/gitlab-ci-templates'
    file:
      - '/stages.yml'
      - '/patterns/platform-service.yml'

variables:
  APP_NAME: my-platform-svc
  ESO_NAMESPACE: my-namespace      # Namespace for ESO provisioning
  ESO_VAULT_PATHS: "services/my-svc"
  DEPLOY_REPO: infra_and_platform_services/platform-deployments
```

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

### Deploy

| Template | Description |
|----------|-------------|
| `.deploy:argocd-sync` | Trigger ArgoCD sync for staging |
| `.promote:tag-image` | Tag image for production promotion |

### Vault Authentication

| Template | Description |
|----------|-------------|
| `.vault_jwt_auth` | Authenticate to Vault, sets `VAULT_TOKEN` |
| `.harbor_auth` | Fetch Harbor robot credentials from Vault |

Use `.vault_jwt_auth` in custom jobs that need Vault access:

```yaml
my-custom-job:
  <<: *vault_jwt_auth
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
  variables:
    VAULT_ROLE: gitlab-ci-protected   # Only works on protected branches
  script:
    - MY_SECRET=$(vault kv get -field=password kv/services/ci/my-app)
```

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

### "invalid username/password" on Harbor login

- Verify the `forge` (or your) project exists in Harbor — log in via Keycloak and create it
- Check Vault has robot credentials: the platform deploys `robot$ci-push` automatically
- The `$` in `robot$ci-push` must be escaped in shell scripts (`robot\$ci-push`)

### "Vault JWT auth failed"

- Ensure your project is on the GitLab instance at `gitlab.example.com`
- `CI_JOB_JWT_V2` is only available in GitLab 15.7+
- Check the `vault-jwt-auth-setup` Job completed: `kubectl get job vault-jwt-auth-setup -n gitlab`

### "Failed to get Harbor creds from Vault"

- Check `kv/services/harbor/ci-robot` exists in Vault
- Check the `harbor-oidc-setup` Job completed: `kubectl get job harbor-oidc-setup -n harbor`
- The Vault `gitlab-ci-read` policy must include `kv/data/services/harbor/ci-robot`

### Build cache misses

Kaniko uses `${HARBOR_REGISTRY}/ci-cache/${CI_PROJECT_NAME}` for layer caching.
The `ci-cache` project must exist in Harbor. Create it via Harbor UI if needed.

## Reference

- [CI/CD Pipeline Architecture](../architecture/cicd-pipeline.md) — system design
- [Secrets & Configuration](../architecture/secrets-configuration.md) — Vault paths
- [microservice-demo](../../examples/microservice-demo/) — working example
