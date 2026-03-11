# Service Deployment Checklist

## Service Information

- **Service name:** _______________
- **Namespace:** app-_______________
- **Team:** _______________
- **Container image:** harbor.aegisgroup.ch/<upstream>/<image>:<tag>

## Workload Configuration

- **Node selector:** workload-type: general / database
- **Replicas:** ___
- **CPU request:** ___ (e.g., 100m)
- **Memory request:** ___ (e.g., 128Mi)
- **Deployment strategy:** [ ] Deployment [ ] Argo Rollout (canary/blue-green)

## External Dependencies

Check all that apply and fill in details:

- [ ] **PostgreSQL (CNPG)** — DB name: ___, size: ___, node: database
- [ ] **Redis/Valkey** — Sentinel: yes/no, size: ___
- [ ] **MinIO bucket** — Bucket name: ___, estimated size: ___
- [ ] **Keycloak OIDC client** — Redirect URI: ___, PKCE: S256/disabled
- [ ] **Gateway + HTTPRoute** — FQDN: ___, TLS: vault-issuer
- [ ] **TCPRoute (non-HTTP)** — Port: ___, protocol: ___
- [ ] **HPA** — Min: ___, Max: ___, CPU target: ___%
- [ ] **VolumeAutoscaler** — Threshold: ___%, max size: ___
- [ ] **PodDisruptionBudget** — minAvailable: ___ or maxUnavailable: ___
- [ ] **oauth2-proxy** — For services without native OIDC
- [ ] **Root CA trust** — Calls internal HTTPS endpoints: yes/no
- [ ] **ServiceMonitor** — Metrics port: ___, path: /metrics
- [ ] **Argo Rollout** — Strategy: canary / blue-green
- [ ] **Argo Workflow templates** — Use case: CI / batch / pipeline
- [ ] **Custom init steps** — Describe: ___

## Auto-Provisioned (no action needed)

These are automatically created by the init Job:

- Vault policy (eso-reader + eso-writer for namespace)
- ESO roles and SecretStore
- Namespace with ResourceQuota + LimitRange

## Pre-Built Analysis Templates

Available for Argo Rollouts:

- `success-rate` — HTTP success rate >= threshold (default 98%)
- `error-rate` — HTTP error rate < threshold (default 2%)
- `latency-check` — p99 latency < threshold (default 500ms)

## Rollback Plan

_______________
