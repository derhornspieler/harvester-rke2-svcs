# Documentation Redesign — Design Document

- **Status**: Accepted
- **Date**: 2026-03-08
- **Decision**: Redesign entire repository documentation with 7 leadership-readable ecosystem diagrams

## Context

The current documentation is functional but engineer-focused. Leadership needs high-level visuals showing how each ecosystem connects. The existing `docs/architecture.md` (46KB) is too dense for executive consumption.

## Goals

1. **Leadership-readable ecosystem diagrams** — PowerPoint-style, big boxes, simple arrows, color-coded
2. **7 ecosystem documents** — each with a leadership diagram + technical reference
3. **Clean document hierarchy** — executive summary at top, depth as you go deeper
4. **Refreshed deployment guide** and new operations docs

## Ecosystems

| # | Ecosystem | Key Components | Story |
|---|-----------|---------------|-------|
| 1 | Authentication & Identity | Keycloak, OAuth2-proxy, OIDC clients, group RBAC | "How users log in and access services" |
| 2 | Networking & Ingress | Traefik, Gateway API, HTTPRoutes, TLS termination | "How traffic flows from browser to service" |
| 3 | PKI & Certificates | Root CA, Vault Intermediate, cert-manager, leaf certs | "How we issue and manage TLS certificates" |
| 4 | CI/CD Pipeline | GitLab, Runners, Harbor, ArgoCD, Argo Rollouts | "How code goes from commit to production" |
| 5 | Observability & Monitoring | Prometheus, Grafana, Loki, Alloy, Hubble, Alertmanager | "How we see what's happening and get alerted" |
| 6 | Data & Storage | CNPG PostgreSQL, Redis/Valkey, MinIO, backups | "How data is stored, replicated, and backed up" |
| 7 | Secrets & Configuration | Vault KV, ESO, SecretStores, credential lifecycle | "How secrets are created, stored, and delivered" |

## Document Structure

```
docs/
  README.md                          # Executive summary (replaces current)
  architecture/
    overview.md                      # Platform overview with master diagram
    authentication-identity.md       # Ecosystem 1
    networking-ingress.md            # Ecosystem 2
    pki-certificates.md              # Ecosystem 3
    cicd-pipeline.md                 # Ecosystem 4
    observability-monitoring.md      # Ecosystem 5
    data-storage.md                  # Ecosystem 6
    secrets-configuration.md         # Ecosystem 7
  getting-started.md                 # Refreshed deployment guide
  operations/
    day2-operations.md               # Runbooks, SOPs
    troubleshooting.md               # Common issues + fixes
    disaster-recovery.md             # Backup/restore procedures
  plans/                             # Existing (keep as-is)
```

## Diagram Style Guide

- **Mermaid** format (renders in GitLab/GitHub, exportable)
- **Large nodes** with descriptive labels (not technical names)
- **Color-coded**: security=red/crimson, data=blue, compute=green, identity=purple, monitoring=orange
- **Minimal text** on arrows — one verb or short phrase
- **Flow direction**: top-to-bottom or left-to-right (consistent per diagram)
- **No YAML, no port numbers, no namespace names** in leadership diagrams
- **Each diagram tells ONE story** answerable in one sentence

## Approach

- Use tech-doc-keeper agent for comprehensive documentation generation
- Each ecosystem doc: leadership diagram (top) + technical details (bottom)
- Cross-link between ecosystems where they interact
- Preserve existing design docs in plans/ untouched

## Consequences

- Old `docs/architecture.md` replaced by `docs/architecture/` directory
- README.md updated to point to new structure
- Service-level READMEs remain as-is (per-service detail)
