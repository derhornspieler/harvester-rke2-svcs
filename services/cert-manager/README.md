# cert-manager

Automated TLS certificate management via Vault PKI.

## Architecture

- ClusterIssuer `vault-issuer` calls Vault `pki_int/sign/<role>` endpoint
- Gateway API shim auto-creates Certificate resources from Gateway annotations
- cert-manager does NOT hold any CA key -- it is a requestor only

## Deployment

Deployed by `scripts/deploy-pki-secrets.sh` phases 1 and 5.

## Monitoring

- Alerts: CertExpiringSoon (<7d), CertNotReady (15m), CertManagerDown (5m)
- Grafana dashboard: certificate expiry timeline, readiness, controller sync rate
