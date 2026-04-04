# PgBouncer Connection Pooling and Read-Replica Load Balancing

Standard operating procedure for GitLab PostgreSQL connection pooling via CNPG PgBouncer Pooler CRs.

## Architecture

```
GitLab Rails / Sidekiq (writes)
    |
    v
gitlab-pg-pooler-rw (PgBouncer, 2 pods, transaction mode)
    |
    v
gitlab-postgresql primary (1 instance)

GitLab Rails (SELECT queries)
    |
    v
gitlab-pg-pooler-ro (PgBouncer, 2 pods, transaction mode)
    |
    v
gitlab-postgresql replicas (2 instances)
```

**CNPG PostgreSQL cluster**: 3 instances (1 primary + 2 replicas) in namespace `database`.

**PgBouncer Pooler CRs**:

| Pooler | Pods | Type | Purpose |
|--------|------|------|---------|
| `gitlab-pg-pooler-rw` | 2 | rw | Write traffic to primary |
| `gitlab-pg-pooler-ro` | 2 | ro | Read traffic to replicas |

**Pooling mode**: Transaction. The application opens many connections; PgBouncer multiplexes them over a smaller pool to PostgreSQL.

**Parameters**:

| Parameter | Value | Description |
|-----------|-------|-------------|
| `max_client_conn` | 400 | Max connections PgBouncer accepts from clients |
| `default_pool_size` | 25 | Connections per user/database pair to PostgreSQL |
| `max_db_connections` | 50 | Hard cap on total backend connections per database |

## Helm Values Configuration

The following values in `services/gitlab/values-rke2-prod.yaml` route GitLab traffic through PgBouncer:

```yaml
global:
  psql:
    host: gitlab-pg-pooler-rw.database.svc.cluster.local
    preparedStatements: false   # REQUIRED for PgBouncer transaction mode
    load_balancing:
      hosts:
        - gitlab-pg-pooler-ro.database.svc.cluster.local

  praefect:
    psql:
      host: gitlab-pg-pooler-rw.database.svc.cluster.local
```

`preparedStatements: false` is mandatory. PgBouncer in transaction mode reassigns backend connections between transactions, so server-side prepared statements break across transaction boundaries.

## Monitoring

### Connection counts on the primary

```bash
kubectl exec -n database gitlab-postgresql-1 -c postgres -- \
  psql -U postgres -c "SELECT count(*), state FROM pg_stat_activity GROUP BY state;"
```

### Prometheus metrics

| Metric | What it tells you |
|--------|-------------------|
| `cnpg_backends_total{cnpg_cluster="gitlab-postgresql"}` | Active backend connections per instance |
| `cnpg_pg_stat_replication_sent_diff_bytes` | Replication lag in bytes (replica health) |

With pooling active, `cnpg_backends_total` should stay well below 400 (the `max_connections` on the CNPG cluster).

### PgBouncer admin interface

Connect to a pooler pod and query PgBouncer stats:

```bash
# List pooler pods
kubectl get pods -n database -l cnpg.io/poolerName=gitlab-pg-pooler-rw

# Check active connections and pool stats
kubectl exec -n database <pooler-pod> -- \
  psql -p 6432 -U pgbouncer pgbouncer -c "SHOW POOLS;"

# Check client and server connection counts
kubectl exec -n database <pooler-pod> -- \
  psql -p 6432 -U pgbouncer pgbouncer -c "SHOW STATS;"
```

### Pooler CR status

```bash
kubectl get pooler -n database
kubectl describe pooler gitlab-pg-pooler-rw -n database
kubectl describe pooler gitlab-pg-pooler-ro -n database
```

## Troubleshooting

### 1. Connection exhaustion

**Symptom**: GitLab returns `FATAL: too many connections` or Rails logs `ActiveRecord::ConnectionNotEstablished`.

**Check**: Verify GitLab is connecting through PgBouncer, not directly to the CNPG `-rw` service.

```bash
# Connections should come from pooler pods, not Rails pods
kubectl exec -n database gitlab-postgresql-1 -c postgres -- \
  psql -U postgres -c "SELECT client_addr, count(*) FROM pg_stat_activity WHERE datname='gitlabhq_production' GROUP BY client_addr ORDER BY count DESC;"
```

**Fix**: Confirm Helm values point to `gitlab-pg-pooler-rw.database.svc.cluster.local`, not `gitlab-postgresql-rw.database.svc.cluster.local`.

### 2. Read replica lag

**Symptom**: Rails falls back to primary for all reads. GitLab logs `Database load balancing: host is not available`.

Rails falls back to primary if replica lag exceeds 8 MB or 60 seconds.

```bash
# Check replication lag
kubectl exec -n database gitlab-postgresql-1 -c postgres -- \
  psql -U postgres -c "SELECT application_name, sent_lsn, write_lsn, flush_lsn, replay_lsn, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes FROM pg_stat_replication;"
```

**Fix**: Investigate replica I/O or CPU pressure. Check if replicas are on `database` node pool and not starved.

### 3. PgBouncer pod down

**Symptom**: Connection refused errors from GitLab.

CNPG manages the Pooler deployment automatically. If a pod is down, check the Pooler CR and pod events:

```bash
kubectl get pooler -n database
kubectl get pods -n database -l cnpg.io/poolerName=gitlab-pg-pooler-rw
kubectl logs -n database -l cnpg.io/poolerName=gitlab-pg-pooler-rw --tail=50
```

**Fix**: CNPG should self-heal. If the Pooler CR is stuck, delete the pooler pod and let the deployment recreate it:

```bash
kubectl delete pod -n database -l cnpg.io/poolerName=gitlab-pg-pooler-rw
```

### 4. Adjusting pool size

Edit the Pooler CR parameters. CNPG performs a rolling restart of PgBouncer pods automatically.

```bash
kubectl edit pooler gitlab-pg-pooler-rw -n database
# Modify spec.pgbouncer.parameters as needed
```

Or patch directly:

```bash
kubectl patch pooler gitlab-pg-pooler-rw -n database --type merge -p '
spec:
  pgbouncer:
    parameters:
      default_pool_size: "30"
      max_client_conn: "500"
'
```

Ensure `max_client_conn` across all pooler pods does not exceed `max_connections` (400) on the CNPG cluster.

## Manifest Locations

| File | Description |
|------|-------------|
| `services/gitlab/pgbouncer-poolers.yaml` | Pooler CRs (rw + ro) |
| `services/gitlab/cloudnativepg-cluster.yaml` | CNPG Cluster CR (`max_connections=400`) |
| `services/gitlab/values-rke2-prod.yaml` | GitLab Helm values (psql host, load_balancing, preparedStatements) |
