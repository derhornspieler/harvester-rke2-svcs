# Dev Team — harvester-rke2-svcs

## Patterns & Conventions
- Each service: own directory under `services/`, own namespace
- Kustomize structure: `base/` + `monitoring/` + root `kustomization.yaml`
- Gateway API (Traefik) for ingress — not legacy Ingress resources
- cert-manager ClusterIssuer: `vault-issuer` (Vault PKI backend)
- ESO SecretStore per namespace, Vault KV v2 backend
- Harbor pull-through cache for ALL images — no direct pulls
- No `latest` tags — pin to semver or digest
- Shell scripts: `set -euo pipefail`, ShellCheck clean

## Service Template Checklist
- [ ] namespace.yaml
- [ ] kustomization.yaml (root + base/)
- [ ] Gateway + HTTPRoute (TLS via cert-manager)
- [ ] SecretStore + ExternalSecret (ESO/Vault)
- [ ] NetworkPolicy (default-deny + explicit allow)
- [ ] ServiceAccount (per-workload, not default)
- [ ] Resource requests + limits on all containers
- [ ] Probes: liveness, readiness, startup
- [ ] PDB for HA services
- [ ] monitoring/ subdirectory (ServiceMonitor, dashboard, alerts)

## ADRs
(None yet — will be added as decisions are made)
