# Harbor Bundle Design

**Date:** 2026-03-04
**Status:** Approved
**Bundle:** 3 of 6

## Overview

Deploy a production-grade container registry with pull-through proxy cache, private image storage, vulnerability scanning, and S3/PostgreSQL/Redis backends.

## Services

| Service | Mode | Purpose |
|---------|------|---------|
| Harbor | Helm chart (goharbor/harbor-helm 1.18.2) | Container registry + proxy cache + Trivy scanning |
| MinIO | Manual deployment | S3-compatible object storage (Harbor blobs + CNPG backups) |
| CNPG PostgreSQL | Operator-managed (3-instance) | Harbor database (HA, daily Barman backups) |
| Valkey/Redis | OpsTree Operator (3+3 Sentinel) | Harbor cache + job queue |

## Architecture

```
Internet/Cluster → Traefik Gateway (TLS) → Harbor
                                             ├── core (API, auth, tokens)
                                             ├── portal (Web UI)
                                             ├── registry (Docker v2 distribution)
                                             ├── jobservice (async jobs)
                                             ├── trivy (vulnerability scanning)
                                             └── exporter (Prometheus metrics)

Harbor → MinIO (S3 blobs)
Harbor → CNPG PostgreSQL (metadata)
Harbor → Valkey Sentinel (cache, job queue)
CNPG   → MinIO (Barman WAL backups)
```

## Directory Structure

```
services/harbor/
├── kustomization.yaml
├── namespace.yaml
├── harbor-values.yaml
├── gateway.yaml
├── httproute.yaml
├── hpa-core.yaml (2-5 replicas)
├── hpa-registry.yaml (2-5 replicas)
├── hpa-trivy.yaml (1-4 replicas)
├── MANIFEST.yaml
├── README.md
├── minio/
│   ├── namespace.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── pvc.yaml (200Gi)
│   ├── external-secret.yaml
│   └── job-create-buckets.yaml
├── postgres/
│   ├── external-secret.yaml
│   ├── harbor-pg-cluster.yaml (3-instance PostgreSQL 16.6)
│   └── harbor-pg-scheduled-backup.yaml
├── valkey/
│   ├── external-secret.yaml
│   ├── replication.yaml (3 replicas)
│   └── sentinel.yaml (3 instances)
└── monitoring/
    ├── kustomization.yaml
    ├── service-monitor.yaml
    ├── service-monitor-valkey.yaml
    ├── service-monitor-minio.yaml
    ├── harbor-alerts.yaml (5 rules)
    ├── minio-alerts.yaml (3 rules)
    ├── configmap-dashboard-harbor.yaml
    └── configmap-dashboard-minio.yaml
```

## Deploy Script (scripts/deploy-harbor.sh)

| Phase | Component | What Happens |
|-------|-----------|--------------|
| 1 | Namespaces | Create harbor, minio, database namespaces |
| 2 | ESO SecretStores | Configure Vault-backed SecretStores for each namespace |
| 3 | MinIO | Deploy MinIO, wait for ready, create buckets (harbor, cnpg-backups) |
| 4 | PostgreSQL | Apply CNPG cluster (3-instance), wait for primary, apply scheduled backup |
| 5 | Valkey | Apply RedisReplication + RedisSentinel, wait for all pods |
| 6 | Harbor Helm | Substitute values, helm install, wait for core/registry/jobservice |
| 7 | Ingress + HPAs | Gateway, HTTPRoute, 3 HPAs |
| 8 | Monitoring + Verify | Apply monitoring, verify TLS, test Harbor health API |

## Resource Conventions

- **Requests only, no limits** for all components
- **HPA:** Harbor core (2-5), registry (2-5), trivy (1-4) at 70% CPU
- **Storage autoscaler:** MinIO PVC (200Gi), CNPG PVCs (20Gi each)
- **Anti-affinity:** CNPG replicas, Redis replicas, Harbor core/registry spread across nodes
- **Node selectors:** MinIO/CNPG/Valkey on `workload-type: database`, Harbor on `workload-type: general`

## Secrets (Vault/ESO)

| Secret | Namespace | Vault Path | Keys |
|--------|-----------|------------|------|
| minio-root-credentials | minio | services/minio/root-credentials | root-user, root-password |
| harbor-pg-credentials | database | services/database/harbor-pg | username, password |
| cnpg-minio-credentials | database | services/database/cnpg-minio | ACCESS_KEY_ID, ACCESS_SECRET_KEY |
| harbor-valkey-credentials | harbor | services/harbor/valkey | password |

## CHANGEME Tokens

| Token | Purpose |
|-------|---------|
| CHANGEME_DOMAIN | Base domain for Harbor URL |
| CHANGEME_DOMAIN_DASHED | TLS secret naming |
| CHANGEME_HARBOR_ADMIN_PASSWORD | Harbor admin password |
| CHANGEME_HARBOR_MINIO_SECRET_KEY | MinIO root password |
| CHANGEME_MINIO_ENDPOINT | MinIO S3 endpoint |
| CHANGEME_HARBOR_DB_PASSWORD | PostgreSQL password |
| CHANGEME_HARBOR_REDIS_PASSWORD | Valkey password |

## Proxy Cache Configuration

Post-deploy, Harbor API is used to create proxy cache projects for:
- docker.io (Docker Hub)
- ghcr.io (GitHub Container Registry)
- quay.io (Red Hat Quay)
- registry.k8s.io (Kubernetes)
- gcr.io (Google Container Registry)

This is documented as a post-deploy step, not automated in the deploy script.

## Dependencies

- Bundle 1 (PKI & Secrets): TLS certs, Vault secrets, ESO
- Bundle 2 (Monitoring): Prometheus for ServiceMonitors and dashboards
- CNPG Operator: Must be installed on the cluster (CRD dependency)
- OpsTree Redis Operator: Must be installed on the cluster (CRD dependency)
