# harvester-rke2-svcs

Service deployments for RKE2 clusters.

## Quick Start

    cp scripts/.env.example scripts/.env
    # Edit scripts/.env with your domain and Root CA key path
    ./scripts/deploy-pki-secrets.sh

## Service Bundles

| Bundle | Services | Status |
|--------|----------|--------|
| PKI & Secrets | Vault, cert-manager, ESO, PKI tooling | Active |

## Structure

    services/           # One directory per service (Kustomize + Helm values)
    scripts/            # Deploy scripts and utility modules
    scripts/utils/      # Small focused shell modules (log, helm, wait, vault, subst)
    docs/plans/         # Design documents and implementation plans
    memory/             # Project memory for Claude Code agents

## Requirements

- RKE2 cluster with kubeconfig access
- kubectl, helm, jq, openssl
- Root CA key (offline, for initial PKI setup only)
