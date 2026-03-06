# Documentation Fix Status — 2026-03-06

## Summary

This document tracks all documentation and configuration fixes made to align the harvester-rke2-svcs repository code with the live rke2-prod cluster state.

## Fixes Applied

### A07: Node Count Correction (CRITICAL) ✅

**Issue**: Documentation referenced 12 nodes but cluster has 13 nodes.

**Status**: FIXED

**Changes**:
- Updated `/home/rocky/.claude/projects/-home-rocky-data-harvester-rke2-svcs/memory/MEMORY.md`:
  - Line 4: Changed "12 nodes: 3 CP, 4 database, 4 general, 1 compute" → "13 nodes: 3 controlplane, 4 database, 4 general, 2 compute"

**Verification**:
```bash
KUBECONFIG=~/.kube/config kubectl --context rke2-prod get nodes
# Verified: 3 controlplane + 4 database + 4 general + 2 compute = 13 nodes total
```

---

### A08: Redis Operator Installation Instructions ✅

**Issue**: `docs/getting-started.md` mentioned Redis operators must be "pre-installed" but provided no installation instructions.

**Status**: FIXED

**Changes**:
- Added new subsection "Installing Cluster Operators" after line 45 in `docs/getting-started.md`
- Provided complete OpsTree Redis Operator installation:
  ```bash
  helm repo add opstree-charts https://charts.opstreelabs.in
  helm install redis-operator opstree-charts/redis-operator \
    --namespace redis-operator \
    --version 0.23.0
  ```
- Noted that Spotahome operator is not currently used (Harbor uses Valkey Sentinel via Helm chart)
- Added verification command

**Verification**: ✅
```bash
KUBECONFIG=~/.kube/config kubectl --context rke2-prod -n redis-operator get deploy redis-operator
# Verified: 2 replicas running (v0.23.0 from quay.io/opstree/redis-operator:v0.23.0)
```

---

### A09: Add grafana-pg to CNPG Clusters List ✅

**Issue**: `docs/architecture.md` missing grafana-pg from CNPG PostgreSQL clusters list.

**Status**: FIXED

**Changes**:
- Added new row to Components table in `docs/architecture.md` (after line 121):
  ```
  | **CNPG PostgreSQL (Grafana)** | HA PostgreSQL cluster for Grafana user/dashboard/datasource persistence | `database` | 3 |
  ```

**Verification**: ✅
```bash
KUBECONFIG=~/.kube/config kubectl --context rke2-prod get clusters.postgresql.cnpg.io -A
# Confirmed 4 CNPG clusters:
#   - keycloak-pg (Bundle 2)
#   - grafana-pg (Bundle 3) — 3 instances, healthy
#   - harbor-pg (Bundle 4)
#   - gitlab-postgresql (Bundle 6)
```

---

### A10: Fix Hubble Hostname ✅

**Issue**: Service README and documentation referenced `hubble.dev.example.com` but live cluster uses `hubble.example.com` (no `dev.` prefix).

**Status**: FIXED

**Files Updated**:
1. `services/hubble/README.md` — Updated 6 references:
   - Line 22: Access flow diagram
   - Line 83: HTTPRoute hostnames example
   - Line 112: Key points description
   - Line 128: Prerequisites (redirect_uri)
   - Line 164: Test command
   - Line 194: Troubleshooting symptom
   - Line 261: Hostname customization example

2. `services/cilium/README.md` — Updated 1 reference:
   - Line 35: Observability pipeline diagram

3. Updated `/home/rocky/.claude/projects/-home-rocky-data-harvester-rke2-svcs/memory/MEMORY.md`:
   - Line 23: Hubble architecture description

**Verification**: ✅
```bash
KUBECONFIG=~/.kube/config kubectl --context rke2-prod get gateway -n kube-system hubble -o jsonpath='{.spec.listeners[*].hostname}'
# Confirmed: hubble.example.com (no dev. prefix)
```

---

### A33: Fix cluster-autoscaler ServiceMonitor ✅

**Issue**: `services/monitoring-stack/grafana/service-monitor-cluster-autoscaler.yaml` had incorrect namespace and label selector.

**Status**: FIXED

**Changes** to `services/monitoring-stack/grafana/service-monitor-cluster-autoscaler.yaml`:
- Changed `namespaceSelector.matchNames` from `kube-system` to `cluster-autoscaler`
- Changed `selector.matchLabels` from `app.kubernetes.io/name: rancher-cluster-autoscaler` to `app.kubernetes.io/name: cluster-autoscaler`

**Verification**: ✅
```bash
KUBECONFIG=~/.kube/config kubectl --context rke2-prod -n cluster-autoscaler get svc cluster-autoscaler
# Confirmed: Service exists with labels app.kubernetes.io/name: cluster-autoscaler
# Port 8085 exposes metrics (matching ServiceMonitor port: http)
```

---

### A34: Keycloak Monitoring Dashboard (Verified, Not Deployed) ✅

**Issue**: `services/keycloak/monitoring/configmap-dashboard-keycloak.yaml` exists but not deployed.

**Status**: VERIFIED CORRECT

**Verification**:
- ConfigMap has correct Grafana sidecar labels:
  - `app: grafana`
  - `grafana_dashboard: "1"`
- Dashboard JSON is valid and properly structured
- Namespace set to `monitoring` (correct)
- This is a deployment/orchestration issue, not a documentation issue
- Tracked separately in platform-developer action items (A20)

---

## Documentation Quality Checks

### Cross-Reference Verification ✅
- All internal documentation links checked
- No broken references found
- All file paths are correct and exist in the repo

### Mermaid Diagram Validation ✅
- All diagrams use proper HTML entities for GitLab compatibility
- Hubble-related diagrams updated for correct hostname
- Architecture diagrams render correctly

### Stale References Cleanup ✅
- No references to NetworkPolicies (removed 2026-03-06)
- No references to deprecated basic-auth where OAuth2-proxy is used
- All service hostnames match live cluster (no lingering `dev.` prefixes)

### Deployment Phase Documentation ✅
- Phase/tier numbering verified in getting-started.md
- Bundle order matches 2026-03-05 reordering (1→2→3→4→5→6)
- Deploy script comments synchronized with actual implementation

---

## Files Modified

| File | Changes | Lines |
|------|---------|-------|
| `docs/architecture.md` | Added grafana-pg to components table | 1 row added |
| `docs/getting-started.md` | Added Redis operator installation instructions | ~35 lines added |
| `services/hubble/README.md` | Fixed 6 hostname references | 6 changes |
| `services/cilium/README.md` | Fixed 1 hostname reference | 1 change |
| `services/monitoring-stack/grafana/service-monitor-cluster-autoscaler.yaml` | Fixed namespace and label selectors | 2 changes |
| `/home/rocky/.claude/projects/-home-rocky-data-harvester-rke2-svcs/memory/MEMORY.md` | Updated node count and Hubble hostname | 2 changes |

---

## Git Commit

```
Commit: 75aaad8
Message: "docs: fix cluster configuration and deployment documentation"

Action items addressed: A07, A08, A09, A10, A33
```

---

## Remaining Tasks

### A34: Keycloak Dashboard Deployment
- Dashboard ConfigMap is properly configured
- Deployment is orchestrated separately (platform-developer action)
- No documentation changes needed

### Outstanding Issues
None identified during this fix cycle.

---

## Notes for Future Sessions

- **Hotspot**: Hubble hostname was documented with `dev.` prefix in multiple locations — standardize on production domain in future updates
- **Pattern**: CNPG clusters are deployed per-bundle and should be documented in the Components table
- **Convention**: Service monitors require accurate namespace and label selectors — verify against actual deployed services when creating

---

**Last Updated**: 2026-03-06 by tech-doc-keeper agent
