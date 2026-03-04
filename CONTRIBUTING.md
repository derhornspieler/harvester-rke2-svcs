# Contributing

Thank you for your interest in contributing to this project. This document
covers how to add new services, coding conventions, and the pull request
process.

## Adding a New Service

Each service lives under `services/<name>/` with a standard layout:

```
services/<name>/
├── kustomization.yaml          # Kustomize entrypoint
├── namespace.yaml              # Namespace resource
├── README.md                   # Service-specific documentation
├── <helm-values>.yaml          # Helm values (if Helm-installed)
├── monitoring/
│   ├── kustomization.yaml
│   ├── service-monitor.yaml    # Prometheus ServiceMonitor
│   ├── <name>-alerts.yaml      # PrometheusRules
│   └── configmap-dashboard-<name>.yaml  # Grafana dashboard JSON
└── <additional manifests>      # Gateway, HTTPRoute, RBAC, etc.
```

### Checklist for a new service

- [ ] Create `services/<name>/namespace.yaml` with the namespace definition
- [ ] Create `services/<name>/kustomization.yaml` listing all resources
- [ ] If Helm-installed, add the Helm install to `scripts/deploy-pki-secrets.sh`
      or create a dedicated deploy script under `scripts/`
- [ ] Add monitoring: ServiceMonitor, PrometheusRules, Grafana dashboard
- [ ] Use `CHANGEME_*` tokens in manifests for domain-specific values
      (see [Placeholder Substitution](docs/architecture.md#placeholder-substitution))
- [ ] Add the token replacement to `scripts/utils/subst.sh` if new tokens
      are needed
- [ ] Write a `README.md` documenting the service architecture, deployment,
      and monitoring
- [ ] Ensure `kustomize build services/<name>/` succeeds
- [ ] Ensure all YAML files pass `yamllint -d relaxed`

## Shell Script Conventions

All shell scripts must follow these rules:

1. **Start with `set -euo pipefail`** -- fail early on errors, undefined
   variables, and broken pipes.

2. **ShellCheck clean** -- all scripts must pass
   `shellcheck --severity=warning`. Run locally before committing:
   ```bash
   shellcheck scripts/deploy-pki-secrets.sh
   shellcheck scripts/utils/*.sh
   shellcheck services/pki/generate-ca.sh
   ```

3. **Quote all variables** -- `"$var"`, not `$var`.

4. **Use `[[ ]]` for conditionals** -- not `[ ]`.

5. **Use utility modules** -- source `scripts/utils/log.sh` for logging,
   `scripts/utils/helm.sh` for Helm operations, etc. Do not duplicate
   functionality that already exists in the utility modules.

6. **Functions under 50 lines** -- break large operations into focused
   functions with descriptive names.

7. **No hardcoded domains or organization names** -- use `CHANGEME_*` tokens
   in manifests and environment variables in scripts.

## YAML Conventions

1. **yamllint clean** -- all YAML files (except Grafana dashboard ConfigMaps)
   must pass `yamllint -d relaxed`:
   ```bash
   yamllint -d relaxed services/<name>/*.yaml
   ```

2. **Kustomize build** -- every service directory with a `kustomization.yaml`
   must produce valid output:
   ```bash
   kustomize build services/<name>/
   ```

3. **Use 2-space indentation** consistently.

4. **Pin versions** -- Helm chart versions, image tags, and CRD versions must
   be pinned to specific versions. Never use `latest`.

5. **Placeholder tokens** -- use `CHANGEME_DOMAIN`, `CHANGEME_DOMAIN_DASHED`,
   `CHANGEME_DOMAIN_DOT`, or `CHANGEME_VAULT_ADDR` for values that vary per
   deployment. Add new tokens to `scripts/utils/subst.sh`.

## Commit Messages

Use imperative mood. Explain **why**, not **what**.

```
<type>: <short summary>

<optional body explaining why this change was made>

Co-Authored-By: Your Name <your@email.com>
```

**Types:**

| Type | When to use |
|------|-------------|
| `feat` | New service, feature, or capability |
| `fix` | Bug fix |
| `refactor` | Code restructure without behavior change |
| `docs` | Documentation only |
| `chore` | CI, tooling, gitignore, linting config |
| `test` | Adding or updating tests |

**Examples:**

```
feat: add ESO SecretStore template for application namespaces

Provides a reusable SecretStore manifest that teams can copy into their
namespace to sync secrets from Vault KV v2.

Co-Authored-By: Jane Doe <jane@example.com>
```

```
fix: correct Vault K8s auth role for cert-manager namespace binding

The cert-manager-issuer role was bound to the wrong namespace, causing
ClusterIssuer to fail authentication against Vault.
```

## Pull Request Process

1. **Branch from `main`** using the naming convention:
   - `feat/<short-description>` for new features
   - `fix/<short-description>` for bug fixes
   - `refactor/<short-description>` for refactoring
   - `docs/<short-description>` for documentation
   - `chore/<short-description>` for tooling and CI

2. **Keep PRs focused** -- one logical change per PR. If a PR touches
   multiple unrelated areas, split it.

3. **Run CI checks locally** before pushing:
   ```bash
   # ShellCheck
   find . -name '*.sh' -not -path './.git/*' | xargs shellcheck --severity=warning

   # yamllint
   find services/ -name '*.yaml' -not -name '*dashboard*' | xargs yamllint -d relaxed

   # Kustomize build (for each service)
   kustomize build services/vault/
   kustomize build services/cert-manager/
   kustomize build services/external-secrets/
   ```

4. **PR description** must include:
   - **Summary** -- what changed and why (1--3 bullet points)
   - **Test plan** -- how you verified the change works

5. **All CI checks must pass** before merge. The CI pipeline runs ShellCheck,
   yamllint, and Kustomize build validation.

## Security

- **Never commit secrets** -- private keys, tokens, passwords, or API keys
  must never appear in the repository. Use `.gitignore` patterns and Vault
  for secrets management.
- **Pin image digests or semver** -- no `latest` tags in production manifests.
- **Review `.gitignore`** -- when adding new credential file types, add the
  corresponding pattern to `.gitignore`.
- If you discover a security vulnerability, report it privately rather than
  opening a public issue.

## Questions?

Open an issue if something is unclear or you need help with the contribution
process.
