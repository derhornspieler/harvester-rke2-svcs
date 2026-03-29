# External Secrets Operator

Syncs secrets from Vault KV v2 to Kubernetes Secrets.

## Architecture

- Per-namespace SecretStore resources (not ClusterSecretStore)
- Each namespace gets a Vault K8s auth role `eso-<namespace>`
- Refresh interval: 15 minutes

## Deployment

Deployed by `scripts/deploy-pki-secrets.sh` phase 6.

## Adding Secrets for a New Service

1. Create a Vault K8s auth role for the namespace
2. Create a SecretStore in the namespace
3. Create ExternalSecret resources mapping Vault paths to K8s Secret keys

## Monitoring

- Alerts: ESODown (5m), SyncFailure (10m), ReconcileErrors (15m)
- Grafana dashboard: sync status, reconcile rate, error tracking
