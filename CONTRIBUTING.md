# Contributing

Thank you for your interest in contributing. This document covers how to add services or improve the platform.

## Choose Your Contribution Type

### Adding a New Service (Developers)

See [Developer's Guide](docs/developer-guide/application-design.md) for service architecture patterns.

Follow these steps:

1. [Use the microservice-demo as a template](examples/microservice-demo/)
2. Implement your service
3. Add `.gitlab-ci.yml` for CI/CD
4. Create Kubernetes manifests
5. Add ArgoCD Application or Fleet bundle

### Improving the Platform (Operators)

See [Operator's Guide](docs/operator-guide/index.md) for platform architecture.

To add a new platform service:

1. Create `services/<name>/` directory
2. Add Kustomize `kustomization.yaml`
3. Add Helm values or raw manifests
4. Add monitoring (ServiceMonitor, PrometheusRules, dashboards)
5. Create Fleet bundle in `fleet-gitops/` under the appropriate bundle group
6. Push charts and bundles to Harbor via `fleet-gitops/scripts/push-charts.sh` and `push-bundles.sh`
7. Deploy via Fleet GitOps: `fleet-gitops/scripts/deploy-fleet-helmops.sh`
8. Update documentation

### Updating Documentation

If you fix typos, clarify procedures, or add guides:

1. Edit the relevant `.md` file
2. Verify markdown with `markdownlint`
3. Test links and code examples
4. Commit with `docs:` prefix

## Shell Script Conventions

All shell scripts must follow these rules:

1. **Start with `set -euo pipefail`** -- fail early on errors
2. **ShellCheck clean** -- pass `shellcheck --severity=warning`
3. **Quote all variables** -- `"$var"`, not `$var`
4. **Use `[[ ]]` for conditionals** -- not `[ ]`
5. **Functions under 50 lines** -- break large operations into focused functions
6. **No hardcoded domains** -- use `CHANGEME_*` tokens

## YAML Conventions

1. **yamllint clean** -- pass `yamllint -d relaxed`
2. **Kustomize builds** -- `kustomize build services/<name>/` must produce valid output
3. **Use 2-space indentation** consistently
4. **Pin versions** -- no `latest` tags

## Commit Messages

Use imperative mood. Explain **why**, not **what**.

```
<type>: <short summary>

<optional body explaining why>

Co-Authored-By: Your Name <your@email.com>
```

Types: `feat`, `fix`, `refactor`, `docs`, `chore`, `test`

## Pull Request Process

1. Branch from `main` with naming: `feat/`, `fix/`, `docs/`, etc.
2. Keep PRs focused -- one logical change
3. Run CI checks locally before pushing
4. Write clear PR description with test plan
5. All CI checks must pass before merge

## Questions?

Open an issue or ask in the documentation.
