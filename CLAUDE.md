# CLAUDE.md — harvester-rke2-svcs

Project instructions for Claude Code. Read this file first on every interaction.

## Project Overview

Production-grade platform services for a 13-node Harvester RKE2 cluster.
Provides identity (Keycloak), container registry (Harbor), GitOps (ArgoCD),
CI/CD (GitLab), observability (Prometheus/Grafana/Loki), and secrets
management (Vault + ESO), all protected by zero-trust PKI.

## Cluster Provisioning

Clusters are provisioned via **Rancher API script** (not Terraform). The
Rancher management cluster handles cluster lifecycle, node provisioning, and
RKE2 configuration. There is no Terraform state or HCL to manage.

## Deployment Method: Fleet GitOps

All platform services deploy through **Rancher Fleet GitOps**. The deployment
path is:

```
fleet-gitops/           # GitOps deployment repo (subdirectory of this repo)
  scripts/
    deploy-fleet-helmops.sh   # Main deploy script (creates HelmOps on Rancher mgmt cluster)
    push-bundles.sh           # Push OCI bundle artifacts to Harbor
    push-charts.sh            # Push Helm charts to Harbor
  00-operators/         # Bundle group: CNPG, Redis, node-labeler, autoscalers
  05-pki-secrets/       # Bundle group: Vault, cert-manager, ESO
  10-identity/          # Bundle group: Keycloak, OAuth2-proxy
  20-monitoring/        # Bundle group: Prometheus, Grafana, Loki, Alloy, Hubble
  30-harbor/            # Bundle group: Harbor, MinIO, CNPG, Valkey
  40-gitops/            # Bundle group: ArgoCD, Argo Rollouts, Argo Workflows
  50-gitlab/            # Bundle group: GitLab, Runners, CNPG, Redis
```

**37 total bundles** across 7 bundle groups, deployed in strict dependency order.

### Deployment Workflow

1. Push Helm charts to Harbor: `./scripts/push-charts.sh`
2. Push Fleet bundles to Harbor: `./scripts/push-bundles.sh`
3. Deploy HelmOps to Rancher management cluster: `./scripts/deploy-fleet-helmops.sh`

The legacy `scripts/deploy-*.sh` scripts in the repo root are **deprecated**.
All new deployments use Fleet GitOps exclusively.

## Project Structure

```
harvester-rke2-svcs/
  fleet-gitops/           # Fleet GitOps bundles (THE deployment path)
    scripts/              # deploy-fleet-helmops.sh, push-bundles.sh, push-charts.sh
    00-operators/         # Cluster operators bundle group
    05-pki-secrets/       # PKI and secrets bundle group
    10-identity/          # Identity bundle group
    20-monitoring/        # Monitoring bundle group
    30-harbor/            # Harbor bundle group
    40-gitops/            # GitOps bundle group
    50-gitlab/            # GitLab bundle group
  services/               # Service definitions, Kustomize overlays, manifests
    pki/                  # Root CA generation, intermediate management
    vault/                # Vault HA configuration
    cert-manager/         # cert-manager configuration
    external-secrets/     # ESO configuration
    keycloak/             # Keycloak + OAuth2-proxy
    monitoring-stack/     # Prometheus, Grafana, Loki, Alloy
    harbor/               # Harbor registry
    argo/                 # ArgoCD, Rollouts, Workflows
    gitlab/               # GitLab EE
    cilium/               # Cilium CNI
    hubble/               # Hubble network observability
  scripts/                # Legacy deploy scripts (DEPRECATED — use fleet-gitops/)
  docs/                   # Architecture docs, operator/developer guides
  memory/                 # Project memory for Claude Code
  examples/               # Example microservice templates
```

## CA/TLS Architecture

Three-tier PKI hierarchy:

1. **Offline Root CA** — Air-gapped, 30-year validity, RSA 4096, nameConstraints
2. **Vault Intermediate CA** — Online, signs leaf certs via Vault PKI engine
3. **Leaf certificates** — Issued by cert-manager via `vault-issuer` ClusterIssuer

The Root CA key is used exactly once: during Vault intermediate CA signing
(bundle 05-pki-secrets). After that, it goes back to offline storage.

## Secrets Management

- **Vault** (HA Raft, 3 replicas) — KV v2 for secrets, PKI engine for certs
- **ESO** (External Secrets Operator) — Syncs Vault secrets to K8s Secrets
- **SecretStore per namespace** — Each namespace has its own Vault auth role
- No secrets in code, environment variables, or CI/CD variables
- `vault-init.json` is gitignored — contains unseal keys and root token

## Dual Repo Sync

This repo (`harvester-rke2-svcs`) contains service definitions and manifests.
The `fleet-gitops/` subdirectory contains Fleet bundle definitions that
reference Helm charts and values from Harbor OCI registry. Changes to service
configurations flow through:

1. Update service manifests/values in `services/`
2. Update Fleet bundle in `fleet-gitops/`
3. Push charts/bundles to Harbor
4. Fleet reconciles on the target cluster

## Conventions

- **Images**: All pulled through Harbor pull-through cache (`harbor.aegisgroup.ch`)
- **Tags**: Pinned to semver or digest, never `latest`
- **Ingress**: Gateway API (Traefik), not legacy Ingress resources
- **TLS**: cert-manager ClusterIssuer `vault-issuer`
- **Secrets**: ESO + Vault KV v2, never raw K8s Secrets
- **Shell scripts**: `set -euo pipefail`, ShellCheck clean, quote all variables
- **YAML**: yamllint clean, 2-space indentation
- **Commits**: Imperative mood, explain "why"
- **Domain**: `aegisgroup.ch` (use `CHANGEME_*` tokens in committed manifests)
