# GitLab CI/CD Patterns

CI/CD pipeline patterns and templates.

## Microservice Pipeline

Build, test, scan, and push to Harbor.

```yaml
stages:
  - build
  - test
  - scan
  - push
  - deploy
```

## Library Pipeline

Build, test, publish to Package Registry.

## Infrastructure Pipeline

Lint, validate, and deploy IaC.

## Coming Soon

Complete CI/CD patterns, security scanning, artifact handling, and template examples.

See [CI/CD Pipeline Architecture](../architecture/cicd-pipeline.md) for system design.
See [microservice-demo](../../examples/microservice-demo/) for a working `.gitlab-ci.yml`.
