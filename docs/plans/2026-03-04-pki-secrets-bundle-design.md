# PKI & Secrets Bundle Design

**Date:** 2026-03-04
**Status:** Approved
**Author:** derhornspieler + Claude Opus 4.6

## Overview

Deploy a complete PKI and secrets management stack onto a fresh or existing RKE2 cluster. This is the foundational bundle that all other services depend on for TLS certificates and secret management.

## PKI Model

```
Offline Root CA (30yr, RSA 4096, nameConstraints)
  └── Vault Intermediate CA (pathlen:0, key inside Vault only)
        ├── cert-manager (vault-issuer) → signs leaf TLS certs via Gateway API shim
        └── ESO → syncs Vault KV v2 secrets to K8s Secrets
```

**Key decisions:**
- Root CA key stays offline, only used to sign Vault intermediate
- Vault intermediate has `pathlen:0` — leaf certs only, no sub-intermediates
- cert-manager is a consumer (not a CA) — calls Vault `pki_int/sign/<role>` endpoint
- nameConstraints at Root level: `example.com`, `cluster.local`, RFC 1918 ranges
- TLS terminated at Traefik (Gateway API), not at Vault

## Directory Structure

```
harvester-rke2-svcs/
├── services/
│   ├── pki/                        # PKI tooling (not a K8s service)
│   │   ├── generate-ca.sh          # CA generation (root, intermediate, leaf)
│   │   ├── README.md
│   │   ├── .gitignore              # Ignores *-key.pem
│   │   ├── roots/
│   │   │   └── aegis-group-root-ca.pem
│   │   └── intermediates/
│   │       └── vault/
│   │           └── README.md
│   ├── vault/
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── vault-values.yaml       # Helm values: 3-replica HA Raft
│   │   ├── gateway.yaml            # Gateway API + cert-manager annotation
│   │   ├── httproute.yaml
│   │   ├── README.md
│   │   └── monitoring/
│   │       ├── kustomization.yaml
│   │       ├── service-monitor.yaml
│   │       ├── vault-alerts.yaml
│   │       └── configmap-dashboard-vault.yaml
│   ├── cert-manager/
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── rbac.yaml               # SA + Role + RoleBinding for vault-issuer
│   │   ├── cluster-issuer.yaml     # ClusterIssuer -> Vault pki_int
│   │   ├── README.md
│   │   └── monitoring/
│   │       ├── kustomization.yaml
│   │       ├── service-monitor.yaml
│   │       ├── certmanager-alerts.yaml
│   │       └── configmap-dashboard-cert-manager.yaml
│   └── external-secrets/
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       ├── README.md
│       └── monitoring/
│           ├── kustomization.yaml
│           ├── servicemonitor.yaml
│           ├── external-secrets-alerts.yaml
│           └── configmap-dashboard-external-secrets.yaml
├── scripts/
│   ├── deploy-pki-secrets.sh       # Bootstrap orchestrator (7 phases)
│   ├── .env.example                # Required env vars template
│   └── utils/
│       ├── log.sh                  # Logging: log_info, log_ok, log_warn, log_error, die
│       ├── vault.sh                # Vault: vault_exec, vault_init, vault_unseal
│       ├── helm.sh                 # Helm: helm_install_if_needed, helm_repo_add
│       ├── wait.sh                 # Waits: wait_for_pods_ready, wait_for_deployment
│       └── subst.sh               # Domain: _subst_changeme
└── docs/plans/                     # This file
```

## Orchestration Model

**Hybrid:** Shell script for bootstrap, ArgoCD for steady-state.

### Bootstrap (deploy-pki-secrets.sh)

| Phase | Component | What Happens |
|-------|-----------|--------------|
| 1 | cert-manager | Helm install (CRDs, gateway-shim enabled) |
| 2 | Vault | Helm install (3-replica HA Raft) -> init -> unseal -> Raft join |
| 3 | PKI | Import Root CA -> generate intermediate CSR inside Vault -> sign with Root key -> import chain |
| 4 | Vault K8s Auth | Enable K8s auth -> create cert-manager-issuer role -> create ESO roles |
| 5 | cert-manager Integration | Apply RBAC -> Apply ClusterIssuer -> verify TLS issuance |
| 6 | ESO | Helm install -> verify controller ready |
| 7 | Kustomize Overlays | Apply monitoring, gateways, httproutes via kustomize build |

**CLI interface:**
```bash
./scripts/deploy-pki-secrets.sh                    # Full deploy
./scripts/deploy-pki-secrets.sh --phase 2          # Single phase
./scripts/deploy-pki-secrets.sh --from 5           # Resume from phase
./scripts/deploy-pki-secrets.sh --unseal-only      # Just unseal Vault
./scripts/deploy-pki-secrets.sh --validate         # Health check all components
```

### Steady-State (ArgoCD)

Post-bootstrap, ArgoCD Application per service manages:
- Monitoring resources (ServiceMonitors, alerts, dashboards)
- Gateway + HTTPRoute manifests
- Namespace labels and annotations

Helm releases remain managed by the deploy script (not ArgoCD Helm source) to avoid drift during Vault unseal operations.

## Script Modules (scripts/utils/)

Each module is small (~30-50 lines), `set -euo pipefail`, ShellCheck clean.

| Module | Functions | Purpose |
|--------|-----------|---------|
| `log.sh` | log_info, log_ok, log_warn, log_error, die, start_phase, end_phase | Colored logging with phase tracking |
| `vault.sh` | vault_exec, vault_init, vault_unseal_all, vault_kv_put, vault_enable_pki, vault_sign_intermediate | Vault CLI operations via kubectl exec |
| `helm.sh` | helm_repo_add, helm_install_if_needed, resolve_helm_chart | Idempotent Helm operations |
| `wait.sh` | wait_for_pods_ready, wait_for_deployment, wait_for_tls_secret, wait_for_clusterissuer | K8s readiness checks with timeout |
| `subst.sh` | _subst_changeme, kube_apply_subst | Domain placeholder substitution |

## Key Conventions

- All images via Harbor pull-through cache (`harbor.example.com`)
- No `latest` tags — pin to semver
- `CHANGEME_DOMAIN` placeholder in manifests, substituted at deploy time
- Vault listens on HTTP internally, TLS terminated at Traefik Gateway
- Per-namespace ESO SecretStore (not ClusterSecretStore) for isolation
- Monitoring on every service: ServiceMonitor + PrometheusRules + Grafana dashboard

## Security

- Root CA key gitignored, stored offline
- Vault intermediate key never leaves Vault
- Shamir unsealing: 5 shares, threshold 3
- vault-init.json gitignored and backed up separately
- Container security: non-root, read-only rootfs, drop all capabilities
- Default-deny NetworkPolicies per namespace
- All secrets via Vault KV v2 -> ESO -> K8s Secrets (no raw secrets in manifests)

## Future Services

After this bundle, additional services deploy independently under `services/`:
- `services/monitoring-stack/` — Prometheus, Grafana, Loki
- `services/keycloak/` — OIDC provider
- `services/harbor/` — Container registry
- `services/argocd/` — GitOps engine
- etc.

Each gets its own deploy script (if imperative steps needed) or is purely ArgoCD-managed.
