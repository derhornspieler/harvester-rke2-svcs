# Harbor Bundle Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy a production-grade Harbor container registry with MinIO (S3), CNPG PostgreSQL (3-instance HA), and Valkey Redis Sentinel backends.

**Architecture:** Harbor Helm chart for the registry, manual Kustomize manifests for MinIO/CNPG/Valkey backends. All secrets via Vault/ESO. Gateway API + Traefik for ingress. 8-phase deploy script.

**Tech Stack:** Harbor Helm 1.18.2, MinIO RELEASE.2024-11-07, CNPG PostgreSQL 16.6, OpsTree Redis v7.0.15, Gateway API v1, Kustomize.

**Source reference:** `../rke2-cluster-via-rancher/services/harbor/` for all manifests.

**Conventions:** Requests only (no limits), HPA on stateless Harbor components, storage autoscaler on PVCs, anti-affinity on replicated workloads, node selectors (database/general).

**Agents:** Use platform-developer for implementation, tech-doc-keeper for docs, security-sentinel for scrub.

---

## Task 1: Harbor Namespace + Gateway + HTTPRoute + HPAs

**Files:**
- Create: `services/harbor/namespace.yaml`
- Create: `services/harbor/gateway.yaml`
- Create: `services/harbor/httproute.yaml`
- Create: `services/harbor/hpa-core.yaml`
- Create: `services/harbor/hpa-registry.yaml`
- Create: `services/harbor/hpa-trivy.yaml`

### Step 1: Copy from source

```bash
mkdir -p services/harbor
cp ../rke2-cluster-via-rancher/services/harbor/namespace.yaml services/harbor/
cp ../rke2-cluster-via-rancher/services/harbor/gateway.yaml services/harbor/
cp ../rke2-cluster-via-rancher/services/harbor/httproute.yaml services/harbor/
cp ../rke2-cluster-via-rancher/services/harbor/hpa-core.yaml services/harbor/
cp ../rke2-cluster-via-rancher/services/harbor/hpa-registry.yaml services/harbor/
cp ../rke2-cluster-via-rancher/services/harbor/hpa-trivy.yaml services/harbor/
```

### Step 2: Commit

```bash
git add services/harbor/
git commit -m "feat: add Harbor namespace, gateway, httproute, and HPAs"
```

---

## Task 2: Harbor Helm Values

**Files:**
- Create: `services/harbor/harbor-values.yaml`

### Step 1: Copy and adapt

```bash
cp ../rke2-cluster-via-rancher/services/harbor/harbor-values.yaml services/harbor/
```

### Step 2: Remove all resource limits

Edit `services/harbor/harbor-values.yaml`:
- Remove ALL `limits:` blocks for every component (core, portal, registry, jobservice, trivy, exporter, nginx)
- Keep all `requests:` blocks
- Keep all `CHANGEME_*` placeholders as-is

### Step 3: Commit

```bash
git add services/harbor/harbor-values.yaml
git commit -m "feat: add Harbor Helm values (requests only, no limits)"
```

---

## Task 3: MinIO Sub-Component

**Files:**
- Create: `services/harbor/minio/namespace.yaml`
- Create: `services/harbor/minio/deployment.yaml`
- Create: `services/harbor/minio/service.yaml`
- Create: `services/harbor/minio/pvc.yaml`
- Create: `services/harbor/minio/external-secret.yaml`
- Create: `services/harbor/minio/job-create-buckets.yaml`

### Step 1: Copy from source

```bash
mkdir -p services/harbor/minio
cp ../rke2-cluster-via-rancher/services/harbor/minio/namespace.yaml services/harbor/minio/
cp ../rke2-cluster-via-rancher/services/harbor/minio/deployment.yaml services/harbor/minio/
cp ../rke2-cluster-via-rancher/services/harbor/minio/service.yaml services/harbor/minio/
cp ../rke2-cluster-via-rancher/services/harbor/minio/pvc.yaml services/harbor/minio/
cp ../rke2-cluster-via-rancher/services/harbor/minio/external-secret.yaml services/harbor/minio/
cp ../rke2-cluster-via-rancher/services/harbor/minio/job-create-buckets.yaml services/harbor/minio/
```

### Step 2: Remove limits from MinIO deployment

Edit `services/harbor/minio/deployment.yaml` — remove `limits:` block, keep only `requests:`.

### Step 3: Commit

```bash
git add services/harbor/minio/
git commit -m "feat: add MinIO S3 storage for Harbor (deployment, PVC, bucket job)"
```

---

## Task 4: PostgreSQL CNPG Sub-Component

**Files:**
- Create: `services/harbor/postgres/external-secret.yaml`
- Create: `services/harbor/postgres/harbor-pg-cluster.yaml`
- Create: `services/harbor/postgres/harbor-pg-scheduled-backup.yaml`

### Step 1: Copy from source

```bash
mkdir -p services/harbor/postgres
cp ../rke2-cluster-via-rancher/services/harbor/postgres/external-secret.yaml services/harbor/postgres/
cp ../rke2-cluster-via-rancher/services/harbor/postgres/harbor-pg-cluster.yaml services/harbor/postgres/
cp ../rke2-cluster-via-rancher/services/harbor/postgres/harbor-pg-scheduled-backup.yaml services/harbor/postgres/
```

### Step 2: Remove limits from CNPG cluster

Edit `services/harbor/postgres/harbor-pg-cluster.yaml` — remove `limits:` block, keep only `requests:`.

Note: CNPG cluster manifests may contain `CHANGEME_MINIO_ENDPOINT` — this is expected and handled by `kube_apply_subst` at deploy time.

### Step 3: Commit

```bash
git add services/harbor/postgres/
git commit -m "feat: add CNPG PostgreSQL cluster for Harbor (3-instance HA, Barman backups)"
```

---

## Task 5: Valkey Redis Sentinel Sub-Component

**Files:**
- Create: `services/harbor/valkey/external-secret.yaml`
- Create: `services/harbor/valkey/replication.yaml`
- Create: `services/harbor/valkey/sentinel.yaml`

### Step 1: Copy from source

```bash
mkdir -p services/harbor/valkey
cp ../rke2-cluster-via-rancher/services/harbor/valkey/external-secret.yaml services/harbor/valkey/
cp ../rke2-cluster-via-rancher/services/harbor/valkey/replication.yaml services/harbor/valkey/
cp ../rke2-cluster-via-rancher/services/harbor/valkey/sentinel.yaml services/harbor/valkey/
```

### Step 2: Remove limits from Redis resources

Edit `services/harbor/valkey/replication.yaml` and `sentinel.yaml` — remove `limits:` blocks, keep only `requests:`.

### Step 3: Commit

```bash
git add services/harbor/valkey/
git commit -m "feat: add Valkey Redis Sentinel for Harbor (3+3 HA)"
```

---

## Task 6: Harbor Monitoring

**Files:**
- Copy all monitoring files from source to `services/harbor/monitoring/`

### Step 1: Copy from source

```bash
mkdir -p services/harbor/monitoring
cp ../rke2-cluster-via-rancher/services/harbor/monitoring/*.yaml services/harbor/monitoring/
```

Expected files: kustomization.yaml, service-monitor.yaml, service-monitor-valkey.yaml, service-monitor-minio.yaml, harbor-alerts.yaml, minio-alerts.yaml, configmap-dashboard-harbor.yaml, configmap-dashboard-minio.yaml

### Step 2: Commit

```bash
git add services/harbor/monitoring/
git commit -m "feat: add Harbor monitoring (ServiceMonitors, alerts, Grafana dashboards)"
```

---

## Task 7: Root Kustomization

**Files:**
- Create: `services/harbor/kustomization.yaml`

### Step 1: Create kustomization

Adapt from source — exclude ArgoCD application, exclude local fallback secrets (use ESO only), exclude coredns/traefik configs (cluster-level).

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  # MinIO
  - minio/namespace.yaml
  - minio/external-secret.yaml
  - minio/pvc.yaml
  - minio/deployment.yaml
  - minio/service.yaml
  - minio/job-create-buckets.yaml
  # PostgreSQL CNPG
  - postgres/external-secret.yaml
  - postgres/harbor-pg-cluster.yaml
  - postgres/harbor-pg-scheduled-backup.yaml
  # Valkey Redis Sentinel
  - valkey/external-secret.yaml
  - valkey/replication.yaml
  - valkey/sentinel.yaml
  # Ingress
  - gateway.yaml
  - httproute.yaml
  # Scaling
  - hpa-core.yaml
  - hpa-registry.yaml
  - hpa-trivy.yaml
  # Monitoring
  - monitoring/
```

### Step 2: Validate

```bash
kubectl kustomize services/harbor/
```

Note: May warn about unknown CRD types (CNPG Cluster, RedisReplication, etc.) — this is expected if CRDs aren't installed locally.

### Step 3: Commit

```bash
git add services/harbor/kustomization.yaml
git commit -m "feat: add Harbor root kustomization"
```

---

## Task 8: Deploy Script (deploy-harbor.sh)

**Files:**
- Create: `scripts/deploy-harbor.sh`

### Step 1: Create 8-phase deploy script

Follow the same patterns as `deploy-pki-secrets.sh` and `deploy-monitoring.sh`:
- Source utils (log, helm, wait, vault, subst, basic-auth)
- Load .env, set up domain vars
- CLI: `--phase N`, `--from N`, `--to N`, `--validate`, `-h/--help`
- Add `HELM_CHART_HARBOR` and `HELM_REPO_HARBOR` env vars

**8 Phases:**

Phase 1: Namespaces (harbor, minio, database)
Phase 2: ESO SecretStores (vault_exec to create K8s auth roles for minio, database, harbor namespaces)
Phase 3: MinIO (apply external-secret, PVC, deployment, service, wait, run bucket job)
Phase 4: PostgreSQL (apply external-secrets, apply CNPG cluster via kube_apply_subst for CHANGEME_MINIO_ENDPOINT, wait for primary, apply scheduled backup)
Phase 5: Valkey (apply external-secret, apply replication, apply sentinel, wait for pods)
Phase 6: Harbor Helm (substitute values, helm install, wait for core/registry/jobservice)
Phase 7: Ingress + HPAs (apply gateway/httproute via kube_apply_subst, apply HPAs)
Phase 8: Monitoring + Verify (apply monitoring kustomize, wait for TLS secret, test Harbor health API)

### Step 2: Make executable, shellcheck clean

```bash
chmod +x scripts/deploy-harbor.sh
shellcheck scripts/deploy-harbor.sh
```

### Step 3: Commit

```bash
git add scripts/deploy-harbor.sh
git commit -m "feat: add deploy-harbor.sh orchestrator (8 phases)"
```

---

## Task 9: Update .env.example + subst.sh

**Files:**
- Modify: `scripts/.env.example`
- Modify: `scripts/utils/subst.sh`

### Step 1: Add Harbor variables to .env.example

```bash
# Harbor admin password
HARBOR_ADMIN_PASSWORD=""

# Harbor component passwords (Vault-synced, but needed for Helm values substitution)
HARBOR_DB_PASSWORD=""
HARBOR_REDIS_PASSWORD=""
HARBOR_MINIO_SECRET_KEY=""

# Harbor Helm chart (override for OCI)
# HELM_CHART_HARBOR="oci://harbor.example.com/charts/harbor"
# HELM_REPO_HARBOR="oci://harbor.example.com/charts"
```

### Step 2: Add CHANGEME tokens to subst.sh

Add to `_subst_changeme()`:
```bash
-e "s|CHANGEME_HARBOR_ADMIN_PASSWORD|${HARBOR_ADMIN_PASSWORD:-}|g" \
-e "s|CHANGEME_HARBOR_DB_PASSWORD|${HARBOR_DB_PASSWORD:-}|g" \
-e "s|CHANGEME_HARBOR_REDIS_PASSWORD|${HARBOR_REDIS_PASSWORD:-}|g" \
-e "s|CHANGEME_HARBOR_MINIO_SECRET_KEY|${HARBOR_MINIO_SECRET_KEY:-}|g" \
-e "s|CHANGEME_MINIO_ENDPOINT|http://minio.minio.svc.cluster.local:9000|g" \
```

### Step 3: Shellcheck, commit

```bash
shellcheck scripts/utils/subst.sh
git add scripts/.env.example scripts/utils/subst.sh
git commit -m "feat: add Harbor env vars and CHANGEME tokens to subst.sh"
```

---

## Task 10: MANIFEST.yaml + README (tech-doc-keeper)

**Files:**
- Create: `services/harbor/MANIFEST.yaml`
- Create: `services/harbor/README.md`

### Step 1: Create MANIFEST.yaml

List all images: Harbor chart components, MinIO, PostgreSQL 16.6, Redis v7.0.15, Redis Sentinel, Redis Exporter, MinIO client (mc).

### Step 2: Create README.md

Architecture, deployment, sub-components, proxy cache setup (post-deploy), monitoring, verify commands.

### Step 3: Commit

```bash
git add services/harbor/MANIFEST.yaml services/harbor/README.md
git commit -m "docs: add Harbor MANIFEST.yaml and README"
```

---

## Task 11: Security Scrub (security-sentinel)

### Step 1: Scan for org-specific info

```bash
grep -rn "aegis\|/home/rocky\|derhornspieler" services/harbor/ scripts/deploy-harbor.sh
```
Expected: zero matches.

### Step 2: Verify no hardcoded secrets

Scan for passwords, tokens, keys in all YAML and shell files. Only `CHANGEME_*` placeholders allowed.

### Step 3: Verify no resource limits

```bash
grep -rn "limits:" services/harbor/ --include="*.yaml" | grep -v "#"
```
Expected: zero matches (or only in commented lines).

### Step 4: Verify CHANGEME coverage

All tokens in Harbor YAML files have matching substitutions in subst.sh.

### Step 5: Kustomize build + ShellCheck

```bash
kubectl kustomize services/harbor/
shellcheck scripts/deploy-harbor.sh
```

### Step 6: Fix issues, commit if needed

---

## Task 12: Push and Monitor CI

### Step 1: Push

```bash
git push origin main
```

### Step 2: Monitor CI

```bash
gh run watch --exit-status
```

### Step 3: Fix any CI failures
