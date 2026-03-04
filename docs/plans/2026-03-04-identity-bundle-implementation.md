# Identity Bundle Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy Keycloak as the centralized OIDC provider with HA PostgreSQL, OAuth2-proxy for non-OIDC services, and a post-deploy setup script for realm/client/group configuration.

**Architecture:** Keycloak 26.0 manual deployment with Infinispan clustering, CNPG PostgreSQL 3-instance HA, OAuth2-proxy instances replacing basic-auth on Prometheus/Alertmanager and adding auth to Hubble. Post-deploy setup-keycloak.sh configures realm, clients, groups.

**Tech Stack:** Keycloak 26.0, CNPG PostgreSQL 16.6, OAuth2-proxy v7.8.1, Gateway API v1, Kustomize.

**Source reference:** `../rke2-cluster-via-rancher/services/keycloak/` for manifests, `../rke2-cluster-via-rancher/scripts/setup-keycloak.sh` for post-deploy setup.

**Agents:** platform-developer for implementation, tech-doc-keeper for docs, security-sentinel for scrub.

---

## Task 1: Keycloak Namespace + Gateway + HTTPRoute

**Files:**
- Create: `services/keycloak/namespace.yaml`
- Create: `services/keycloak/gateway.yaml`
- Create: `services/keycloak/httproute.yaml`

### Step 1: Copy from source

```bash
mkdir -p services/keycloak
cp ../rke2-cluster-via-rancher/services/keycloak/namespace.yaml services/keycloak/
cp ../rke2-cluster-via-rancher/services/keycloak/gateway.yaml services/keycloak/
cp ../rke2-cluster-via-rancher/services/keycloak/httproute.yaml services/keycloak/
```

### Step 2: Commit

```bash
git add services/keycloak/
git commit -m "feat: add Keycloak namespace, gateway, and httproute"
```

---

## Task 2: Keycloak Core Manifests

**Files:**
- Create: `services/keycloak/keycloak/deployment.yaml`
- Create: `services/keycloak/keycloak/hpa.yaml`
- Create: `services/keycloak/keycloak/rbac.yaml`
- Create: `services/keycloak/keycloak/service.yaml`
- Create: `services/keycloak/keycloak/service-headless.yaml`
- Create: `services/keycloak/keycloak/external-secret.yaml`

### Step 1: Copy from source

```bash
mkdir -p services/keycloak/keycloak
cp ../rke2-cluster-via-rancher/services/keycloak/keycloak/deployment.yaml services/keycloak/keycloak/
cp ../rke2-cluster-via-rancher/services/keycloak/keycloak/hpa.yaml services/keycloak/keycloak/
cp ../rke2-cluster-via-rancher/services/keycloak/keycloak/rbac.yaml services/keycloak/keycloak/
cp ../rke2-cluster-via-rancher/services/keycloak/keycloak/service.yaml services/keycloak/keycloak/
cp ../rke2-cluster-via-rancher/services/keycloak/keycloak/service-headless.yaml services/keycloak/keycloak/
cp ../rke2-cluster-via-rancher/services/keycloak/keycloak/external-secret.yaml services/keycloak/keycloak/
```

### Step 2: Remove limits from deployment.yaml

Edit `services/keycloak/keycloak/deployment.yaml` — remove `limits:` block, keep only `requests:`.

Do NOT copy `secret.yaml` (local fallback, use ESO only).

### Step 3: Commit

```bash
git add services/keycloak/keycloak/
git commit -m "feat: add Keycloak deployment, HPA, RBAC, services, external-secret"
```

---

## Task 3: Keycloak PostgreSQL CNPG

**Files:**
- Create: `services/keycloak/postgres/external-secret.yaml`
- Create: `services/keycloak/postgres/keycloak-pg-cluster.yaml`
- Create: `services/keycloak/postgres/keycloak-pg-scheduled-backup.yaml`

### Step 1: Copy from source

```bash
mkdir -p services/keycloak/postgres
cp ../rke2-cluster-via-rancher/services/keycloak/postgres/external-secret.yaml services/keycloak/postgres/
cp ../rke2-cluster-via-rancher/services/keycloak/postgres/keycloak-pg-cluster.yaml services/keycloak/postgres/
cp ../rke2-cluster-via-rancher/services/keycloak/postgres/keycloak-pg-scheduled-backup.yaml services/keycloak/postgres/
```

### Step 2: Remove limits from CNPG cluster

Edit `services/keycloak/postgres/keycloak-pg-cluster.yaml` — remove `limits:` block, keep only `requests:`.

Do NOT copy `secret.yaml`.

### Step 3: Commit

```bash
git add services/keycloak/postgres/
git commit -m "feat: add Keycloak CNPG PostgreSQL (3-instance HA, Barman backups)"
```

---

## Task 4: OAuth2-Proxy Manifests

**Files:**
- Create: `services/keycloak/oauth2-proxy/prometheus.yaml`
- Create: `services/keycloak/oauth2-proxy/alertmanager.yaml`
- Create: `services/keycloak/oauth2-proxy/hubble.yaml`
- Create: `services/keycloak/oauth2-proxy/external-secrets.yaml`

### Step 1: Copy OAuth2-proxy manifests from source monitoring-stack

```bash
mkdir -p services/keycloak/oauth2-proxy
cp ../rke2-cluster-via-rancher/services/monitoring-stack/prometheus/oauth2-proxy.yaml \
   services/keycloak/oauth2-proxy/prometheus.yaml
cp ../rke2-cluster-via-rancher/services/monitoring-stack/alertmanager/oauth2-proxy.yaml \
   services/keycloak/oauth2-proxy/alertmanager.yaml
cp ../rke2-cluster-via-rancher/services/monitoring-stack/kube-system/oauth2-proxy-hubble.yaml \
   services/keycloak/oauth2-proxy/hubble.yaml
```

### Step 2: Copy ExternalSecret manifests

```bash
# Combine the per-service external-secrets into one file or copy individually
cp ../rke2-cluster-via-rancher/services/monitoring-stack/prometheus/external-secret-oauth2-proxy.yaml \
   services/keycloak/oauth2-proxy/external-secret-prometheus.yaml
cp ../rke2-cluster-via-rancher/services/monitoring-stack/alertmanager/external-secret-oauth2-proxy.yaml \
   services/keycloak/oauth2-proxy/external-secret-alertmanager.yaml
cp ../rke2-cluster-via-rancher/services/monitoring-stack/kube-system/external-secret-oauth2-proxy-hubble.yaml \
   services/keycloak/oauth2-proxy/external-secret-hubble.yaml
```

### Step 3: Remove limits from all oauth2-proxy manifests

Edit each — remove `limits:` blocks, keep only `requests:`.

### Step 4: Copy Traefik middleware manifests for oauth2-proxy

```bash
cp ../rke2-cluster-via-rancher/services/monitoring-stack/prometheus/middleware-oauth2-proxy.yaml \
   services/keycloak/oauth2-proxy/middleware-prometheus.yaml
cp ../rke2-cluster-via-rancher/services/monitoring-stack/alertmanager/middleware-oauth2-proxy.yaml \
   services/keycloak/oauth2-proxy/middleware-alertmanager.yaml
cp ../rke2-cluster-via-rancher/services/monitoring-stack/kube-system/middleware-oauth2-proxy-hubble.yaml \
   services/keycloak/oauth2-proxy/middleware-hubble.yaml
```

### Step 5: Commit

```bash
git add services/keycloak/oauth2-proxy/
git commit -m "feat: add OAuth2-proxy for Prometheus, Alertmanager, and Hubble"
```

---

## Task 5: Keycloak Monitoring

**Files:**
- Copy monitoring files from source

### Step 1: Copy from source

```bash
mkdir -p services/keycloak/monitoring
cp ../rke2-cluster-via-rancher/services/keycloak/monitoring/*.yaml services/keycloak/monitoring/
```

Expected: kustomization.yaml, service-monitor.yaml, keycloak-alerts.yaml, configmap-dashboard-keycloak.yaml

### Step 2: Commit

```bash
git add services/keycloak/monitoring/
git commit -m "feat: add Keycloak monitoring (ServiceMonitor, 7 alerts, Grafana dashboard)"
```

---

## Task 6: Root Kustomization

**Files:**
- Create: `services/keycloak/kustomization.yaml`

### Step 1: Create kustomization

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  # Keycloak core
  - keycloak/rbac.yaml
  - keycloak/external-secret.yaml
  - keycloak/service.yaml
  - keycloak/service-headless.yaml
  - keycloak/deployment.yaml
  - keycloak/hpa.yaml
  # PostgreSQL CNPG
  - postgres/external-secret.yaml
  - postgres/keycloak-pg-cluster.yaml
  - postgres/keycloak-pg-scheduled-backup.yaml
  # Ingress
  - gateway.yaml
  - httproute.yaml
  # OAuth2-proxy (deployed in Phase 6 after Keycloak is configured)
  # - oauth2-proxy/prometheus.yaml
  # - oauth2-proxy/alertmanager.yaml
  # - oauth2-proxy/hubble.yaml
  # - oauth2-proxy/external-secret-prometheus.yaml
  # - oauth2-proxy/external-secret-alertmanager.yaml
  # - oauth2-proxy/external-secret-hubble.yaml
  # - oauth2-proxy/middleware-prometheus.yaml
  # - oauth2-proxy/middleware-alertmanager.yaml
  # - oauth2-proxy/middleware-hubble.yaml
  # Monitoring
  - monitoring/
```

Note: OAuth2-proxy resources are commented out in kustomization.yaml because they require Keycloak to be running and configured first. They are applied explicitly in Phase 6 of the deploy script.

### Step 2: Validate

```bash
kubectl kustomize services/keycloak/
```

### Step 3: Commit

```bash
git add services/keycloak/kustomization.yaml
git commit -m "feat: add Keycloak root kustomization"
```

---

## Task 7: Deploy Script (deploy-keycloak.sh)

**Files:**
- Create: `scripts/deploy-keycloak.sh`

### Step 1: Create 7-phase deploy script

Follow established patterns from deploy-pki-secrets.sh and deploy-harbor.sh.

**7 Phases:**

Phase 1: Namespace
Phase 2: ESO SecretStores + ExternalSecrets (admin + postgres creds)
Phase 3: CNPG PostgreSQL (apply cluster via kube_apply_subst, wait for primary, scheduled backup)
Phase 4: Keycloak (apply kustomize for core manifests, wait for deployment ready, health check /realms/master)
Phase 5: Gateway + HTTPRoute + HPA (apply via kube_apply_subst, wait for TLS secret)
Phase 6: OAuth2-proxy (apply all proxy manifests, middleware, external-secrets; update Prometheus/Alertmanager HTTPRoutes to use OAuth2-proxy middleware instead of basic-auth)
Phase 7: Monitoring + Verify (apply monitoring kustomize, verify health)

CLI: `--phase N`, `--from N`, `--to N`, `--validate`, `-h/--help`

Add `CHANGEME_KC_ADMIN_PASSWORD` and `CHANGEME_KEYCLOAK_DB_PASSWORD` to the env vars the script uses.

### Step 2: Make executable, shellcheck clean

```bash
chmod +x scripts/deploy-keycloak.sh
shellcheck scripts/deploy-keycloak.sh
```

### Step 3: Commit

```bash
git add scripts/deploy-keycloak.sh
git commit -m "feat: add deploy-keycloak.sh orchestrator (7 phases)"
```

---

## Task 8: Setup Script (setup-keycloak.sh)

**Files:**
- Create: `scripts/setup-keycloak.sh`

### Step 1: Create post-deploy setup script

Adapted from source `../rke2-cluster-via-rancher/scripts/setup-keycloak.sh`.

This script runs AFTER Keycloak is deployed and healthy. It uses the Keycloak Admin API to configure:

Phase 1: Create `platform` realm, configure security settings
Phase 2: Create `admin-breakglass` user with admin access
Phase 3: Create OIDC clients (grafana, prometheus-oidc, alertmanager-oidc, hubble-oidc)
Phase 4: Create `platform-admins` group, assign admin-breakglass to it
Phase 5: Configure `prompt=login` (no-SSO) flow on all clients
Phase 6: Validation and summary

The script uses `curl` to call the Keycloak Admin API (no kcadm.sh dependency).

CLI: `--from N`, `-h/--help`

### Step 2: Make executable, shellcheck clean

### Step 3: Commit

```bash
git add scripts/setup-keycloak.sh
git commit -m "feat: add setup-keycloak.sh for realm, client, and group configuration"
```

---

## Task 9: Update .env.example + subst.sh

**Files:**
- Modify: `scripts/.env.example`
- Modify: `scripts/utils/subst.sh`

### Step 1: Add Keycloak variables to .env.example

```bash
# Keycloak admin password
KC_ADMIN_PASSWORD=""

# Keycloak database password
KEYCLOAK_DB_PASSWORD=""

# Keycloak realm name
KC_REALM="platform"

# Keycloak bootstrap client secret (generated during setup)
KEYCLOAK_BOOTSTRAP_CLIENT_SECRET=""
```

### Step 2: Add CHANGEME tokens to subst.sh

Add to `_subst_changeme()`:
```bash
-e "s|CHANGEME_KC_ADMIN_PASSWORD|${KC_ADMIN_PASSWORD:-}|g" \
-e "s|CHANGEME_KEYCLOAK_DB_PASSWORD|${KEYCLOAK_DB_PASSWORD:-}|g" \
```

### Step 3: Commit

```bash
git add scripts/.env.example scripts/utils/subst.sh
git commit -m "feat: add Keycloak env vars and CHANGEME tokens"
```

---

## Task 10: MANIFEST.yaml + README (tech-doc-keeper)

**Files:**
- Create: `services/keycloak/MANIFEST.yaml`
- Create: `services/keycloak/README.md`

### Step 1: Create MANIFEST.yaml

Images: Keycloak 26.0, PostgreSQL 16.6, OAuth2-proxy v7.8.1
Charts: None (manual deployment)
All Kustomize resources listed.

### Step 2: Create README.md

Architecture, deployment (deploy-keycloak.sh), post-deploy setup (setup-keycloak.sh), OIDC clients, groups, monitoring, verify.

### Step 3: Commit

```bash
git add services/keycloak/MANIFEST.yaml services/keycloak/README.md
git commit -m "docs: add Keycloak MANIFEST.yaml and README"
```

---

## Task 11: Security Scrub (security-sentinel)

Standard scrub: org-specific info, hardcoded secrets, limits, CHANGEME coverage, kustomize build, shellcheck, image registries.

---

## Task 12: Push and Monitor CI

```bash
git push origin main
gh run watch --exit-status
```
