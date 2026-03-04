# Identity Bundle Design

**Date:** 2026-03-04
**Status:** Approved
**Bundle:** 4 of 6

## Overview

Deploy Keycloak as the centralized OIDC provider with HA PostgreSQL, OAuth2-proxy for non-OIDC services, and a post-deploy setup script for realm/client/group configuration.

## Services

| Service | Mode | Purpose |
|---------|------|---------|
| Keycloak 26.0 | Manual deployment (HA, Infinispan) | OIDC provider, single realm, group RBAC |
| CNPG PostgreSQL | Operator-managed (3-instance) | Keycloak database (HA, Barman backups) |
| OAuth2-proxy v7.8.1 | Per-service deployments | ForwardAuth for Prometheus, Alertmanager, Hubble |

## Identity Model

- **Single realm:** `platform`
- **Bootstrap user:** `admin-breakglass` (group: `platform-admins`, access to all clients + Keycloak admin)
- **Independent sessions:** `prompt=login` on all clients (no SSO redirect)
- **Group-based RBAC:** Keycloak groups control which clients users can access
- **Grafana:** Native OIDC (no OAuth2-proxy needed)
- **Prometheus/Alertmanager/Hubble:** OAuth2-proxy ForwardAuth (replaces basic-auth from Bundle 2)

## Architecture

```
Users → Traefik Gateway (TLS) → Keycloak (OIDC provider)
                                    ├── realm: platform
                                    ├── admin-breakglass (platform-admins)
                                    └── OIDC clients per service

Prometheus → OAuth2-proxy → Keycloak auth check → allow/deny
Alertmanager → OAuth2-proxy → Keycloak auth check → allow/deny
Hubble → OAuth2-proxy → Keycloak auth check → allow/deny
Grafana → Native OIDC → Keycloak auth check → allow/deny

Keycloak → CNPG PostgreSQL (3-instance, database namespace)
CNPG → MinIO (Barman WAL backups)
```

## Directory Structure

```
services/keycloak/
├── kustomization.yaml
├── namespace.yaml
├── gateway.yaml
├── httproute.yaml
├── keycloak/
│   ├── deployment.yaml
│   ├── hpa.yaml (2-5 replicas)
│   ├── rbac.yaml
│   ├── service.yaml
│   ├── service-headless.yaml
│   └── external-secret.yaml
├── postgres/
│   ├── external-secret.yaml
│   ├── keycloak-pg-cluster.yaml (3-instance)
│   └── keycloak-pg-scheduled-backup.yaml
├── oauth2-proxy/
│   ├── prometheus.yaml
│   ├── alertmanager.yaml
│   ├── hubble.yaml
│   └── external-secrets.yaml
├── monitoring/
│   ├── kustomization.yaml
│   ├── service-monitor.yaml
│   ├── keycloak-alerts.yaml (7 rules)
│   └── configmap-dashboard-keycloak.yaml
├── MANIFEST.yaml
└── README.md
```

## Deploy Script (scripts/deploy-keycloak.sh) — 7 Phases

| Phase | Component | What Happens |
|-------|-----------|--------------|
| 1 | Namespace | Create keycloak namespace |
| 2 | ESO | SecretStores, ExternalSecrets for admin + postgres creds |
| 3 | PostgreSQL | CNPG cluster (3-instance), wait for primary, scheduled backup |
| 4 | Keycloak | Apply deployment, services, RBAC, wait for ready |
| 5 | Ingress | Gateway, HTTPRoute, HPA, wait for TLS |
| 6 | OAuth2-proxy | Deploy instances for Prometheus/Alertmanager/Hubble, remove basic-auth |
| 7 | Monitoring + Verify | Apply monitoring, health check Keycloak API |

## Post-Deploy Script (scripts/setup-keycloak.sh)

Adapted from source. Run manually after Keycloak is healthy:

1. Create `platform` realm
2. Create `admin-breakglass` user (platform-admins group)
3. Create OIDC clients (grafana, prometheus-oidc, alertmanager-oidc, hubble-oidc)
4. Create groups (platform-admins initially, more added with future bundles)
5. Configure `prompt=login` (no-SSO flow) on all clients
6. Update Grafana Helm values to enable OIDC (uncomment Bundle 4 sections)

Future bundles add their own OIDC clients to this realm:
- Bundle 5: argocd, argo-rollouts
- Bundle 6: gitlab

## Resource Conventions

- **Requests only, no limits**
- **HPA:** Keycloak (2-5 replicas, 70% CPU)
- **Anti-affinity:** Keycloak pods + CNPG replicas spread across nodes
- **Node selectors:** CNPG on `workload-type: database`, Keycloak/OAuth2-proxy on `workload-type: general`
- **Storage autoscaler:** CNPG PVCs (10Gi each)

## Secrets (Vault/ESO)

| Secret | Namespace | Vault Path |
|--------|-----------|------------|
| keycloak-admin-secret | keycloak | services/keycloak/admin-secret |
| keycloak-postgres-secret | keycloak | services/keycloak/postgres-secret |
| keycloak-pg-credentials | database | services/database/keycloak-pg |
| oauth2-proxy-*-oidc | monitoring | oidc/`<service>`-oidc |

## CHANGEME Tokens

| Token | Purpose |
|-------|---------|
| CHANGEME_DOMAIN | Keycloak hostname |
| CHANGEME_DOMAIN_DASHED | TLS secret naming |
| CHANGEME_KC_REALM | Realm name (default: platform) |
| CHANGEME_KC_ADMIN_PASSWORD | Bootstrap admin password |
| CHANGEME_KEYCLOAK_DB_PASSWORD | PostgreSQL password |
| CHANGEME_MINIO_ENDPOINT | MinIO for CNPG backups |

## Dependencies

- Bundle 1 (PKI & Secrets): TLS, Vault, ESO
- Bundle 2 (Monitoring): Prometheus for ServiceMonitors, Grafana for dashboards
- Bundle 3 (Harbor): MinIO for CNPG backups (shared)
- CNPG Operator: Must be installed (CRD dependency)
