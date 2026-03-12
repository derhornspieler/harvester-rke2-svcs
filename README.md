# harvester-rke2-svcs

[![CI](https://github.com/derhornspieler/harvester-rke2-svcs/actions/workflows/ci.yml/badge.svg)](https://github.com/derhornspieler/harvester-rke2-svcs/actions/workflows/ci.yml) [![License](https://img.shields.io/badge/license-Apache%202.0-green)](LICENSE)

Complete platform infrastructure for RKE2 clusters using Fleet GitOps, ArgoCD, and GitLab CI/CD.

## Choose Your Path

### Are You an Operator?

Deploy and maintain the platform infrastructure.

> **[Getting Started Guide](docs/getting-started.md)**

- Unified Fleet deployment (58 bundles, ~40 minutes)
- Automated Vault PKI signing and CI secret seeding
- Day-2 operations, troubleshooting, scaling

### Are You a Developer?

Build applications that run on the platform.

> **[Developer's Guide](docs/developer-guide/index.md)**

- Create services in GitLab with CI/CD
- Deploy with ArgoCD or Fleet
- Integrate with platform services (Keycloak, Vault, monitoring)

### For Everyone

**[Platform Architecture](docs/architecture/overview.md)** -- How the system works

[Ecosystem diagrams and technical deep dives](docs/architecture/)

---

## What Is This?

A complete foundation for production Kubernetes workloads:

- **Identity & Access**: Keycloak OIDC + OAuth2-proxy
- **Security**: Vault secrets + cert-manager TLS
- **CI/CD**: GitLab + Runners + Harbor registry
- **Deployment**: ArgoCD + Argo Rollouts (progressive delivery)
- **Observability**: Prometheus, Grafana, Loki, Alloy, Hubble
- **Data**: PostgreSQL HA, Redis Sentinel, MinIO

All deployed via Fleet GitOps on a 13-node RKE2 cluster.

---

## Quick Links

- **[Documentation Hub](docs/README.md)** -- Navigation for all docs
- **[Contributing Guide](CONTRIBUTING.md)** -- How to add services
- **[Architecture Overview](docs/architecture/overview.md)** -- System design
- **[Platform Landscape](docs/architecture/landscape.md)** -- Full ecosystem visualization
- **[Working Examples](examples/)** -- Clone and adapt

---

## Architecture

See [Platform Overview](docs/architecture/overview.md) for the full diagram.

---

## Getting Started

### For Operators

1. **Prepare your environment:** `cd fleet-gitops && ./scripts/prepare.sh`
2. **Deploy the platform:** Follow [Getting Started Guide](docs/getting-started.md)
3. **Manage day-2 operations:** See Troubleshooting section for token refresh, bundle updates, and scaling

### For Developers

1. [Read the Developer's Guide](docs/developer-guide/index.md)
2. [Follow the Quickstart](docs/developer-guide/quickstart.md)
3. [Clone the working examples](examples/)

---

## Requirements

- RKE2 cluster v1.28+ with 13 nodes
- kubectl, helm, jq, openssl, git
- Domain name and DNS control
- Rancher with Fleet enabled (for operators)

---

## License

Apache License 2.0. See [LICENSE](LICENSE) for details.
