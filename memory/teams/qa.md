# QA Team — harvester-rke2-svcs

## Test Strategy
- Manifest validation: `kustomize build | kubeconform`
- Helm lint: `helm lint` + `helm template` for Helm-based services
- Shell scripts: ShellCheck
- YAML: yamllint
- Security: Trivy container scan, Gitleaks secret scan

## CI Pipeline Standards
- All checks pass before merge
- Pipeline target: <10 minutes
- Security scanning on every PR

## Regression Matrix
(No regressions tracked yet — will populate as services are deployed)
