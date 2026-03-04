# Security Team — harvester-rke2-svcs

## Threat Model
- All secrets via Vault KV v2, synced by ESO — no raw K8s secrets in manifests
- TLS everywhere via cert-manager + Vault PKI (three-tier CA hierarchy)
- Harbor pull-through cache — no direct pulls from untrusted registries
- Pod Security Standards: `restricted` baseline, documented exceptions only
- Default-deny NetworkPolicies in every namespace

## Secret Handling
- Vault paths: `kv/services/<namespace>/<secret-name>`
- ESO refresh interval: 15m default
- No secrets in code, env vars, CI vars, or ConfigMaps
- `.gitignore` covers: tfvars, vault-init.json, .env, keys, kubeconfigs

## Container Security Defaults
- `runAsNonRoot: true`
- `readOnlyRootFilesystem: true`
- `privileged: false`
- `allowPrivilegeEscalation: false`
- Drop ALL capabilities, add only what's needed
- No hostNetwork/hostPID/hostIPC without documented exception

## Compliance
- OWASP Top 10 (2021) — applied to all services
- CIS Kubernetes Benchmark (v1.8) — cluster-level
- DISA STIG for Kubernetes (V1R11) — where applicable
