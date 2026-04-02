# Getting Started with Examples

Working demo projects you can clone and adapt for your own services.

## Platform Demo (microservice-demo)

[Full README](../../examples/microservice-demo/README.md)

A Go web server demonstrating the full platform developer experience:

- Structured JSON logging, Prometheus metrics, health probes
- CI pipeline with efficiency patterns (`changes:` rules, Docker layer caching)
- Dev/staged/prod Kustomize overlays — self-contained, no shared base
- MinimalCD flow: auto-deploy to dev, MR promotion to staged/prod
- All platform conventions: non-root, read-only rootfs, Gateway API

**Structure:**
```
microservice-demo/
  main.go              # Go web server
  Dockerfile           # Multi-stage build
  .gitlab-ci.yml       # CI with build/scan/deploy
  deploy/
    dev/               # Dev overlay (Deployment, Service, HTTPRoute)
    staged/            # Staged overlay
    prod/              # Production overlay
```

**CI Pipeline:**
```yaml
include:
  - component: gitlab.<DOMAIN>/infra_and_platform_services/ci-components/build@1.0.0
    inputs:
      image_name: <TEAM>/<APP>

  - component: gitlab.<DOMAIN>/infra_and_platform_services/ci-components/deploy@1.0.0
    inputs:
      team: <TEAM>
      app: <APP>
```

## Library Demo

[Full README](../../examples/library-demo/README.md)

A shared Go library demonstrating:

- Module structure and semantic versioning
- GitLab Package Registry publishing
- How to import and use in other services

## Which Example to Use?

| Use Case | Example | CI Pattern |
|----------|---------|------------|
| HTTP service with deployment | Platform Demo | build + scan + deploy |
| Shared library (no container) | Library Demo | test + publish |

## What's Next

1. Clone the Platform Demo
2. Update `deploy/` overlays with your team/app name
3. Update `.gitlab-ci.yml` with your CI Catalog component inputs
4. Push to GitLab — CI handles the rest

- [Application Design](application-design.md) — platform conventions
- [GitLab CI](gitlab-ci.md) — pipeline patterns and efficiency
- [ArgoCD Deployment](argocd-deployment.md) — promotion workflow
- [App Onboarding](app-onboarding.md) — platform setup for new apps
