# Harbor Container Registry

Harbor is deployed as a highly available container registry with external
PostgreSQL, Redis (Valkey), and MinIO backing stores.

## Architecture

```
                          ┌──────────────────────────┐
                          │   Traefik (Gateway API)   │
                          └────────┬─────────────────┘
                                   │ TLS termination
                     ┌─────────────┴──────────────┐
                     │      harbor namespace       │
                     │                             │
                     │  ┌───────┐    ┌──────────┐  │
                     │  │ nginx │───▶│   core   │  │
                     │  └───┬───┘    └────┬─────┘  │
                     │      │             │        │
                     │  ┌───▼───┐  ┌──────▼─────┐  │
                     │  │portal │  │ jobservice  │  │
                     │  └───────┘  └────────────┘  │
                     │                             │
                     │  ┌──────────┐  ┌──────────┐ │
                     │  │ registry │  │  trivy   │ │
                     │  └────┬─────┘  └──────────┘ │
                     │       │                     │
                     │  ┌────▼─────┐               │
                     │  │ exporter │               │
                     │  └──────────┘               │
                     └───────┬──────────┬──────────┘
                             │          │
              ┌──────────────┼──────────┼────────────────┐
              │              │          │                 │
      ┌───────▼──────┐  ┌───▼────┐  ┌──▼──────────────┐ │
      │ MinIO (S3)   │  │ Valkey │  │ PostgreSQL (CNPG)│ │
      │ minio ns     │  │ 1+2    │  │ 3-instance HA    │ │
      │ 200Gi PVC    │  │ +sent. │  │ database ns      │ │
      └──────────────┘  └────────┘  └──────────────────┘ │
              │                                          │
              └──────────────────────────────────────────┘
```

## Sub-components

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| **Harbor** (Helm chart) | Core registry: core, portal, registry, jobservice, trivy, exporter, nginx | `harbor` |
| **MinIO** | S3-compatible object storage for registry blobs and CNPG backups | `minio` |
| **PostgreSQL** (CNPG) | HA database cluster (3 instances) for Harbor metadata | `database` |
| **Valkey** (Redis Operator) | Redis Sentinel HA (1 master + 2 replicas + 3 sentinels) for Harbor cache and job queue | `harbor` |

## Prerequisites

Before deploying Harbor, the following operators and services must be running:

- **cert-manager** with a `vault-issuer` ClusterIssuer (TLS certificates)
- **Traefik** with Gateway API support (ingress)
- **CloudNativePG operator** in `cnpg-system` namespace (PostgreSQL)
- **OpsTree Redis operator** in `redis-operator-system` namespace (Valkey)
- **External Secrets Operator** with Vault SecretStores (credentials)
- **Vault** with KV v2 secrets populated for Harbor, MinIO, and CNPG

## Deployment

### Required environment variables

Set these in `scripts/.env` (see `scripts/.env.example`):

```bash
HARBOR_ADMIN_PASSWORD="<strong-password>"
HARBOR_DB_PASSWORD="<db-password>"
HARBOR_REDIS_PASSWORD="<redis-password>"
HARBOR_MINIO_SECRET_KEY="<minio-secret>"
```

### Deploy command

Deployment follows 8 phases (see `MANIFEST.yaml` for full details):

```bash
# Phase 1: Create namespaces
kubectl apply -f services/harbor/namespace.yaml
kubectl apply -f services/harbor/minio/namespace.yaml

# Phase 2: ExternalSecrets (credentials from Vault)
kube_apply_subst services/harbor/minio/external-secret.yaml
kube_apply_subst services/harbor/postgres/external-secret.yaml
kube_apply_subst services/harbor/valkey/external-secret.yaml

# Phase 3: MinIO
kube_apply_subst services/harbor/minio/pvc.yaml \
  services/harbor/minio/deployment.yaml \
  services/harbor/minio/service.yaml

# Phase 4: Create MinIO buckets
kube_apply_subst services/harbor/minio/job-create-buckets.yaml
kubectl wait --for=condition=complete job/minio-create-buckets -n minio --timeout=120s

# Phase 5: PostgreSQL HA
kube_apply_subst services/harbor/postgres/harbor-pg-cluster.yaml \
  services/harbor/postgres/harbor-pg-scheduled-backup.yaml
kubectl wait --for=condition=Ready cluster/harbor-pg -n database --timeout=300s

# Phase 6: Valkey (Redis Sentinel)
kube_apply_subst services/harbor/valkey/replication.yaml
kube_apply_subst services/harbor/valkey/sentinel.yaml

# Phase 7: Harbor Helm chart
helm install harbor oci://registry-1.docker.io/goharbor/harbor-helm \
  -n harbor -f <(kube_apply_subst < services/harbor/harbor-values.yaml) \
  --version 1.18.2

# Phase 8: Ingress, HPAs, monitoring
kube_apply_subst services/harbor/gateway.yaml \
  services/harbor/httproute.yaml
kubectl apply -f services/harbor/hpa-core.yaml \
  -f services/harbor/hpa-registry.yaml \
  -f services/harbor/hpa-trivy.yaml
kubectl apply -k services/harbor/monitoring/
```

## Post-deployment

### Proxy cache setup

Harbor proxy cache endpoints must be configured manually via the Harbor UI or
API after deployment. For each upstream registry you want to cache:

1. Log in to `https://harbor.example.com` as admin.
2. Navigate to **Administration > Registries > New Endpoint**.
3. Add the upstream registry (e.g., Docker Hub, ghcr.io, quay.io, registry.k8s.io).
4. Create a proxy cache project:
   - Navigate to **Projects > New Project**.
   - Check **Proxy Cache** and select the registry endpoint.
   - Name the project to match the upstream (e.g., `dockerhub-cache`, `ghcr-cache`).

Example API call to create a registry endpoint:

```bash
curl -H "Authorization: Basic $(echo -n admin:YOUR_PASSWORD | base64)" -X POST \
  "https://harbor.example.com/api/v2.0/registries" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "dockerhub",
    "type": "docker-hub",
    "url": "https://hub.docker.com",
    "insecure": false
  }'
```

### Traefik timeout

Large image pushes require increasing Traefik's `readTimeout` to at least
600 seconds. See `traefik-timeout-helmchartconfig.yaml` or update the cluster
Traefik chart values.

## Monitoring

### ServiceMonitors (3)

| ServiceMonitor | Target | Namespace |
|----------------|--------|-----------|
| `harbor` | Harbor core, registry, exporter, jobservice metrics | `monitoring` |
| `harbor-valkey` | Redis exporter sidecar on Valkey pods | `monitoring` |
| `minio` | MinIO cluster, bucket, and node metrics | `monitoring` |

### Alerts (9)

| Alert | Severity | Description |
|-------|----------|-------------|
| `HarborDown` | critical | Harbor component unreachable for 5 min |
| `HarborHighErrorRate` | warning | HTTP 5xx rate exceeds 5% for 10 min |
| `HarborQuotaAlmostFull` | warning | Project quota usage above 90% for 30 min |
| `HarborValkeyDown` | critical | Valkey redis-exporter unreachable for 5 min |
| `HarborValkeyHighMemory` | warning | Valkey memory above 80% for 10 min |
| `HarborValkeyReplicationBroken` | warning | Fewer than 2 connected replicas for 5 min |
| `MinIODown` | critical | MinIO instance unreachable for 5 min |
| `MinIODiskAlmostFull` | warning | Disk usage above 85% for 10 min |
| `MinIOHighErrorRate` | warning | S3 error rate above 5% for 5 min |

### Grafana dashboards (2)

| Dashboard | ConfigMap |
|-----------|-----------|
| Harbor overview | `grafana-dashboard-harbor` |
| MinIO overview | `grafana-dashboard-minio` |

## Day-2 Operations

### Clean up stale ReplicaSets

After Helm upgrades or troubleshooting, zero-replica ReplicaSets may accumulate.
Clean them up periodically:

```bash
kubectl -n harbor delete rs $(kubectl -n harbor get rs -o jsonpath='{.items[?(@.spec.replicas==0)].metadata.name}')
```

## Verify

```bash
# Check all pods are running
kubectl get pods -n harbor
kubectl get pods -n minio
kubectl get pods -n database -l cnpg.io/cluster=harbor-pg

# Check Harbor health
curl -sk https://harbor.example.com/api/v2.0/health | jq .

# Verify registry login
docker login harbor.example.com

# Check Valkey sentinel status
kubectl exec -n harbor harbor-redis-sentinel-0 -- redis-cli -p 26379 SENTINEL masters

# Check CNPG cluster status
kubectl get cluster harbor-pg -n database

# Check MinIO bucket
kubectl exec -n minio deploy/minio -- mc alias set local http://localhost:9000 \
  "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" && mc ls local/harbor
```
