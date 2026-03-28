# Platform Demo

A reference implementation showing how to build, scan, and deploy an
application on the platform using the MinimalCD pattern.

## What This Demonstrates

- **Go web server** with health probes, Prometheus metrics, structured JSON logging, and file serving
- **CI pipeline** with efficiency patterns (`changes:` rules, Docker layer caching, deploy skip)
- **Dev/Staged/Prod overlays** — self-contained Kustomize overlays for each environment
- **Platform conventions** — non-root, read-only rootfs, requests only, Gateway API

## Project Structure

```
.
├── main.go                    # Go web server
├── Dockerfile                 # Multi-stage build (builder + alpine runtime)
├── go.mod / go.sum            # Go dependencies
├── .gitlab-ci.yml             # CI pipeline (lint → build → scan → deploy)
└── deploy/
    ├── dev/                   # Dev environment overlay
    │   ├── kustomization.yaml
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   └── httproute.yaml
    ├── staged/                # Staged environment overlay
    │   └── ...
    └── prod/                  # Production environment overlay
        └── ...
```

## How Deployment Works

```
Developer pushes to main
        │
        ▼
CI: lint (if source changed) → build image → scan → deploy
        │
        ▼
deploy:dev job:
  1. Authenticates to Vault (GitLab JWT)
  2. Fetches SSH deploy key from Vault
  3. Clones platform/platform-deployments (dev branch)
  4. Updates image tag via kustomize
  5. Commits and pushes
        │
        ▼
ArgoCD detects change → syncs to cluster (~3 min)
```

### Environment Promotion

| Environment | Trigger | Branch | ArgoCD Sync |
|-------------|---------|--------|-------------|
| **dev** | Auto on merge to main | `dev` | Auto (~3 min) |
| **staged** | Manual (MR to staged branch) | `staged` | Auto after merge |
| **prod** | Manual (MR to prod branch) | `prod` | Manual sync |

## Local Development

```bash
# Run locally
go run main.go

# Build image
buildah bud -t platform-demo:dev .

# Test endpoints
curl http://localhost:8080/          # Index page
curl http://localhost:8080/healthz   # Liveness probe
curl http://localhost:8080/readyz    # Readiness probe
curl http://localhost:8080/metrics   # Prometheus metrics
curl http://localhost:8080/files/    # File browser
```

## Adapting for Your Project

1. Copy this example to your project repo
2. Replace the Go app with your application
3. Update `deploy/*/kustomization.yaml` with your team and app name
4. Update `.gitlab-ci.yml` variables (`DEPLOY_TEAM`, `DEPLOY_APP`, `IMAGE`)
5. Create your overlay folders in `platform/platform-deployments`
6. Push to main — CI handles the rest

## CI Pipeline Efficiency Patterns

| Pattern | How | Why |
|---------|-----|-----|
| `changes:` rules | Only build when `*.go`, `Dockerfile` change | Skip builds on doc-only commits |
| `buildah --layers` | Reuse Docker layers from previous builds | Faster rebuilds (only changed layers) |
| `git diff --quiet` | Skip deploy push if tag is current | No empty commits in platform-deployments |
| Dual tags | `${CI_COMMIT_SHORT_SHA}` + `${CI_COMMIT_REF_SLUG}` | SHA for deploy, branch for dev testing |

## Platform Conventions

| Convention | Implementation |
|------------|---------------|
| Non-root container | `USER 65532` in Dockerfile, `runAsNonRoot: true` |
| Read-only rootfs | `readOnlyRootFilesystem: true`, emptyDir for writable paths |
| Requests only (no limits) | `cpu: 50m, memory: 32Mi` — allows bursting |
| Health probes | `/healthz` (liveness), `/readyz` (readiness), startup probe |
| Prometheus metrics | `/metrics` endpoint + ServiceMonitor CR |
| Structured logging | JSON to stdout (`timestamp`, `level`, `msg`) |
| Gateway API | HTTPRoute (not legacy Ingress) |
| Pod anti-affinity | Spread replicas across nodes |
| Node selector | `workload-type: general` |
