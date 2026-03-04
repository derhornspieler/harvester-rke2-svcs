# harvester-rke2-svcs — Project Memory Index

## Project Overview
- **Purpose**: Service deployments for a freshly installed RKE2 cluster (provisioned by rke2-cluster-via-rancher)
- **Repo**: `/home/rocky/code/harvester-rke2-svcs/`
- **Domain**: `example.com`
- **Registry**: `harbor.example.com` (pull-through cache)
- **Pattern**: Independent service folders, Kustomize-based, Gateway API ingress

## Architecture
- Services are independent unless explicitly bundled (e.g., Vault + cert-manager + ESO)
- Each service gets its own namespace, matching the directory name under `services/`
- Follows patterns established in `rke2-cluster-via-rancher` project
- Gateway API (Traefik) for ingress, cert-manager + Vault PKI for TLS
- ESO + Vault for secrets management

## Team Files
- [Dev](teams/dev.md) — Architecture, patterns, conventions, ADRs
- [Product](teams/product.md) — Requirements, acceptance criteria, roadmap
- [Security](teams/security.md) — Threat model, compliance, secrets
- [QA](teams/qa.md) — Test strategy, coverage, CI
- [Docs](teams/docs.md) — Documentation standards, completeness

## Service Bundles
- `services/pki-secrets-bundle/` — Vault + cert-manager + ESO (deploy together)

## Active Work
- Initial project scaffolding in progress
