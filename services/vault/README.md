# Vault

HashiCorp Vault for secrets management and PKI.

## Architecture

- 3-replica HA cluster with integrated Raft storage
- Shamir unsealing (5 shares, threshold 3)
- TLS terminated at Traefik Gateway (Vault listens on HTTP internally)
- PKI intermediate CA for cert-manager leaf certificate signing

## Deployment

Deployed by `scripts/deploy-pki-secrets.sh` phases 2-4.

## Monitoring

- ServiceMonitor: `/v1/sys/metrics?format=prometheus` (30s interval)
- Alerts: VaultSealed (2m), VaultDown (2m), VaultLeaderLost (10m)
- Grafana dashboard: seal status, Raft health, barrier ops, commit time

## Day-2 Operations

- [Vault Unseal SOP](docs/vault-unseal-sop.md) — step-by-step procedure for unsealing pods after restarts

### Quick Unseal

After pod restart:

    ./scripts/deploy-pki-secrets.sh --unseal-only
