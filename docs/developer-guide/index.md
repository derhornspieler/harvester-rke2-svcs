# Developer's Guide

Welcome! This guide is for application engineers building services that run on the harvester-rke2-svcs platform.

## What You'll Learn

- How to structure applications for the platform
- CI/CD patterns using GitLab pipelines
- Deploying with ArgoCD for fine-grained control
- Deploying with Fleet GitOps for simplicity
- Integrating with platform services (Keycloak, Vault, monitoring)

## Quick Navigation

- **[Quickstart](quickstart.md)** -- Create your first service in 10 minutes
- **[Application Design](application-design.md)** -- Architecture patterns for platform apps
- **[GitLab CI Patterns & Best Practices](gitlab-ci.md)** -- CI/CD workflows, security scanning, quality gates, and pipeline best practices
- **[Testing Standards](testing-standards.md)** -- Test pyramid, coverage targets, CI gates
- **[Harbor Proxy-Cache](harbor-proxy-cache.md)** -- Image pull requirements and registry mapping
- **[ArgoCD Deployment](argocd-deployment.md)** -- Progressive delivery and rollbacks
- **[Fleet Deployment](fleet-deployment.md)** -- When and how to use Fleet GitOps
- **[App Onboarding](app-onboarding.md)** -- Provision OIDC, Vault, and ESO for a new app
- **[Platform Integration](platform-integration.md)** -- Using Keycloak, Vault, monitoring
- **[Troubleshooting](troubleshooting.md)** -- Common issues and solutions
- **[Example Repositories](getting-started-with-examples.md)** -- Working demos to learn from

## Two Deployment Paths

1. **ArgoCD** (recommended for production services)
   - Fine-grained control over deployment strategy
   - Metrics-driven canary and blue-green deployments
   - Full visibility into rollout progress

2. **Fleet GitOps** (recommended for simpler services and dev branches)
   - Lightweight, no rollout controller needed
   - Good for services without complex rollback logic
   - Easier for dev/feature branch deployments

Both paths use Git as the source of truth. Choose based on your needs.

## Architecture Overview

See [Platform Architecture](../architecture/overview.md) for the full system diagram.
See [CI/CD Pipeline Ecosystem](../architecture/cicd-pipeline.md) for deployment flow details.
