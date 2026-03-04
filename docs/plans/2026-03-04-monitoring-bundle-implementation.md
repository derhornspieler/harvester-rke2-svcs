# Monitoring Bundle Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy a full observability stack (Prometheus, Grafana, Loki, Alloy) with 18 dashboards, 9 alert groups, 6 service monitors, and Gateway API ingress with basic-auth.

**Architecture:** kube-prometheus-stack Helm chart for Prometheus/Grafana/Alertmanager. Loki (monolithic initially, upgrade to SimpleScalable later) and Alloy deployed via Kustomize. All ingress via Gateway API + Traefik. Basic-auth on Prometheus/Alertmanager as placeholder until Bundle 4 (Keycloak).

**Tech Stack:** kube-prometheus-stack Helm chart, Loki 3.4.6, Grafana Alloy v1.6.1, Gateway API v1, Traefik, Kustomize.

**Source reference:** `../rke2-cluster-via-rancher/services/monitoring-stack/` for all manifests and configs.

**Conventions:** Requests only (no limits), HPA on Grafana, storage autoscaler on Prometheus/Loki PVCs, anti-affinity on replicated workloads, node selectors (database/general).

---

## Task 1: Script Utilities — Add Monitoring Helpers

**Files:**
- Create: `scripts/utils/basic-auth.sh`

### Step 1: Create basic-auth helper

This module generates a Traefik basic-auth middleware Secret. Needed for Prometheus and Alertmanager until Keycloak replaces it.

```bash
#!/usr/bin/env bash
# basic-auth.sh — Generate htpasswd Secret for Traefik basic-auth middleware
# Source this file; do not execute directly.
# Requires: log.sh sourced first
set -euo pipefail

create_basic_auth_secret() {
  local namespace="$1"
  local name="$2"
  local username="$3"
  local password="$4"

  local htpasswd
  htpasswd=$(htpasswd -nb "$username" "$password")

  log_info "Creating basic-auth secret ${name} in ${namespace}..."
  kubectl create secret generic "$name" \
    --namespace="$namespace" \
    --from-literal=users="$htpasswd" \
    --dry-run=client -o yaml | kubectl apply -f -
  log_ok "Basic-auth secret ${name} created"
}
```

### Step 2: Validate

```bash
shellcheck scripts/utils/basic-auth.sh
```

### Step 3: Commit

```bash
git add scripts/utils/basic-auth.sh
git commit -m "feat: add basic-auth utility for Traefik middleware"
```

---

## Task 2: Monitoring Namespace + Loki

**Files:**
- Create: `services/monitoring-stack/namespace.yaml`
- Create: `services/monitoring-stack/loki/configmap.yaml`
- Create: `services/monitoring-stack/loki/statefulset.yaml`
- Create: `services/monitoring-stack/loki/rbac.yaml`
- Create: `services/monitoring-stack/loki/service.yaml`

### Step 1: Create namespace and Loki resources

Copy from source repo:
```bash
mkdir -p services/monitoring-stack/loki
cp ../rke2-cluster-via-rancher/services/monitoring-stack/namespace.yaml services/monitoring-stack/
cp ../rke2-cluster-via-rancher/services/monitoring-stack/loki/configmap.yaml services/monitoring-stack/loki/
cp ../rke2-cluster-via-rancher/services/monitoring-stack/loki/statefulset.yaml services/monitoring-stack/loki/
cp ../rke2-cluster-via-rancher/services/monitoring-stack/loki/rbac.yaml services/monitoring-stack/loki/
cp ../rke2-cluster-via-rancher/services/monitoring-stack/loki/service.yaml services/monitoring-stack/loki/
```

### Step 2: Remove limits from Loki StatefulSet

Edit `services/monitoring-stack/loki/statefulset.yaml` — remove the `limits:` block, keep only `requests:`.
Change nodeSelector from `workload-type: general` to `workload-type: database` (stateful workload).

### Step 3: Commit

```bash
git add services/monitoring-stack/namespace.yaml services/monitoring-stack/loki/
git commit -m "feat: add monitoring namespace and Loki (monolithic, filesystem)"
```

---

## Task 3: Alloy DaemonSet

**Files:**
- Create: `services/monitoring-stack/alloy/configmap.yaml`
- Create: `services/monitoring-stack/alloy/daemonset.yaml`
- Create: `services/monitoring-stack/alloy/rbac.yaml`
- Create: `services/monitoring-stack/alloy/service.yaml`

### Step 1: Copy from source

```bash
mkdir -p services/monitoring-stack/alloy
cp ../rke2-cluster-via-rancher/services/monitoring-stack/alloy/configmap.yaml services/monitoring-stack/alloy/
cp ../rke2-cluster-via-rancher/services/monitoring-stack/alloy/daemonset.yaml services/monitoring-stack/alloy/
cp ../rke2-cluster-via-rancher/services/monitoring-stack/alloy/rbac.yaml services/monitoring-stack/alloy/
cp ../rke2-cluster-via-rancher/services/monitoring-stack/alloy/service.yaml services/monitoring-stack/alloy/
```

### Step 2: Remove limits from Alloy DaemonSet

Edit `services/monitoring-stack/alloy/daemonset.yaml` — remove the `limits:` block, keep only `requests:`.

### Step 3: Commit

```bash
git add services/monitoring-stack/alloy/
git commit -m "feat: add Alloy DaemonSet for log collection"
```

---

## Task 4: Helm Values (kube-prometheus-stack)

**Files:**
- Create: `services/monitoring-stack/helm/kube-prometheus-stack-values.yaml`
- Create: `services/monitoring-stack/helm/additional-scrape-configs.yaml`

### Step 1: Copy and adapt Helm values

```bash
mkdir -p services/monitoring-stack/helm
cp ../rke2-cluster-via-rancher/services/monitoring-stack/helm/values.yaml \
   services/monitoring-stack/helm/kube-prometheus-stack-values.yaml
cp ../rke2-cluster-via-rancher/services/monitoring-stack/helm/additional-scrape-configs.yaml \
   services/monitoring-stack/helm/
```

### Step 2: Remove all resource limits from Helm values

Edit `services/monitoring-stack/helm/kube-prometheus-stack-values.yaml`:
- Remove `limits:` blocks from: prometheusOperator, prometheus, alertmanager, grafana, node-exporter, kube-state-metrics
- Keep all `requests:` blocks
- Comment out Keycloak OIDC env vars (GF_AUTH_GENERIC_OAUTH_*) with note "Enabled in Bundle 4"
- Comment out `grafana-oidc-secret` envValueFrom
- Comment out `extraVolumeMounts` and `extraVolumes` for vault-root-ca (needed after Keycloak)
- Replace `CHANGEME_GRAFANA_ADMIN_PASSWORD` with a reference to env var: leave as CHANGEME placeholder
- Add HPA section for Grafana (if supported by chart, otherwise note for post-deploy)

### Step 3: Commit

```bash
git add services/monitoring-stack/helm/
git commit -m "feat: add kube-prometheus-stack Helm values and scrape configs"
```

---

## Task 5: Prometheus and Alertmanager Gateways + Basic Auth

**Files:**
- Create: `services/monitoring-stack/prometheus/gateway.yaml`
- Create: `services/monitoring-stack/prometheus/httproute.yaml`
- Create: `services/monitoring-stack/prometheus/basic-auth-middleware.yaml`
- Create: `services/monitoring-stack/alertmanager/gateway.yaml`
- Create: `services/monitoring-stack/alertmanager/httproute.yaml`
- Create: `services/monitoring-stack/alertmanager/basic-auth-middleware.yaml`

### Step 1: Create Prometheus gateway and httproute

Copy gateways from source:
```bash
mkdir -p services/monitoring-stack/prometheus services/monitoring-stack/alertmanager
cp ../rke2-cluster-via-rancher/services/monitoring-stack/prometheus/gateway.yaml services/monitoring-stack/prometheus/
cp ../rke2-cluster-via-rancher/services/monitoring-stack/alertmanager/gateway.yaml services/monitoring-stack/alertmanager/
```

### Step 2: Create simplified HTTPRoutes (basic-auth instead of oauth2-proxy)

For Prometheus — `services/monitoring-stack/prometheus/httproute.yaml`:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: prometheus
  namespace: monitoring
spec:
  parentRefs:
    - name: prometheus
      namespace: monitoring
      sectionName: https
  hostnames:
    - "prometheus.CHANGEME_DOMAIN"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: basic-auth-prometheus
      backendRefs:
        - name: prometheus
          port: 9090
```

For Alertmanager — `services/monitoring-stack/alertmanager/httproute.yaml`:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: alertmanager
  namespace: monitoring
spec:
  parentRefs:
    - name: alertmanager
      namespace: monitoring
      sectionName: https
  hostnames:
    - "alertmanager.CHANGEME_DOMAIN"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: basic-auth-alertmanager
      backendRefs:
        - name: alertmanager
          port: 9093
```

### Step 3: Create Traefik basic-auth Middleware CRDs

For Prometheus — `services/monitoring-stack/prometheus/basic-auth-middleware.yaml`:
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: basic-auth-prometheus
  namespace: monitoring
spec:
  basicAuth:
    secret: basic-auth-prometheus
```

For Alertmanager — `services/monitoring-stack/alertmanager/basic-auth-middleware.yaml`:
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: basic-auth-alertmanager
  namespace: monitoring
spec:
  basicAuth:
    secret: basic-auth-alertmanager
```

### Step 4: Commit

```bash
git add services/monitoring-stack/prometheus/ services/monitoring-stack/alertmanager/
git commit -m "feat: add Prometheus/Alertmanager gateways with basic-auth middleware"
```

---

## Task 6: Grafana Gateway + Dashboards

**Files:**
- Create: `services/monitoring-stack/grafana/gateway.yaml`
- Create: `services/monitoring-stack/grafana/httproute.yaml`
- Copy: 15 dashboard ConfigMaps to `services/monitoring-stack/grafana/dashboards/`

### Step 1: Copy Grafana gateway and httproute

```bash
mkdir -p services/monitoring-stack/grafana/dashboards
cp ../rke2-cluster-via-rancher/services/monitoring-stack/grafana/gateway.yaml services/monitoring-stack/grafana/
cp ../rke2-cluster-via-rancher/services/monitoring-stack/grafana/httproute.yaml services/monitoring-stack/grafana/
```

### Step 2: Copy all 15 dashboard ConfigMaps

```bash
cp ../rke2-cluster-via-rancher/services/monitoring-stack/grafana/configmap-dashboard-*.yaml \
   services/monitoring-stack/grafana/dashboards/
```

### Step 3: Commit

```bash
git add services/monitoring-stack/grafana/
git commit -m "feat: add Grafana gateway, httproute, and 15 platform dashboards"
```

---

## Task 7: PrometheusRules (9 Alert Groups)

**Files:**
- Copy all 9 alert YAML files + kustomization.yaml to `services/monitoring-stack/prometheus-rules/`

### Step 1: Copy from source

```bash
mkdir -p services/monitoring-stack/prometheus-rules
cp ../rke2-cluster-via-rancher/services/monitoring-stack/prometheus-rules/*.yaml \
   services/monitoring-stack/prometheus-rules/
```

### Step 2: Commit

```bash
git add services/monitoring-stack/prometheus-rules/
git commit -m "feat: add 9 PrometheusRule alert groups"
```

---

## Task 8: ServiceMonitors (6 Monitors)

**Files:**
- Copy all 6 monitor YAML files + kustomization.yaml to `services/monitoring-stack/service-monitors/`

### Step 1: Copy from source

```bash
mkdir -p services/monitoring-stack/service-monitors
cp ../rke2-cluster-via-rancher/services/monitoring-stack/service-monitors/*.yaml \
   services/monitoring-stack/service-monitors/
```

### Step 2: Commit

```bash
git add services/monitoring-stack/service-monitors/
git commit -m "feat: add 6 ServiceMonitors (Alloy, Loki, Grafana, CNPG, Hubble, Redis)"
```

---

## Task 9: Service Aliases + Root Kustomization

**Files:**
- Create: `services/monitoring-stack/prometheus-service-alias.yaml`
- Create: `services/monitoring-stack/alertmanager-service-alias.yaml`
- Create: `services/monitoring-stack/kustomization.yaml`

### Step 1: Copy service aliases from source

```bash
cp ../rke2-cluster-via-rancher/services/monitoring-stack/prometheus-service-alias.yaml services/monitoring-stack/
cp ../rke2-cluster-via-rancher/services/monitoring-stack/alertmanager-service-alias.yaml services/monitoring-stack/
```

### Step 2: Create kustomization.yaml

Adapted from source — remove oauth2-proxy references (Bundle 4), remove Keycloak ESO references, include basic-auth middlewares.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  # Loki
  - loki/rbac.yaml
  - loki/configmap.yaml
  - loki/statefulset.yaml
  - loki/service.yaml
  # Alloy
  - alloy/rbac.yaml
  - alloy/configmap.yaml
  - alloy/daemonset.yaml
  - alloy/service.yaml
  # Prometheus Gateway + basic-auth
  - prometheus/gateway.yaml
  - prometheus/httproute.yaml
  - prometheus/basic-auth-middleware.yaml
  # Alertmanager Gateway + basic-auth
  - alertmanager/gateway.yaml
  - alertmanager/httproute.yaml
  - alertmanager/basic-auth-middleware.yaml
  # Grafana Gateway
  - grafana/gateway.yaml
  - grafana/httproute.yaml
  # Grafana dashboards
  - grafana/dashboards/configmap-dashboard-home.yaml
  - grafana/dashboards/configmap-dashboard-firing-alerts.yaml
  - grafana/dashboards/configmap-dashboard-etcd.yaml
  - grafana/dashboards/configmap-dashboard-apiserver.yaml
  - grafana/dashboards/configmap-dashboard-node-detail.yaml
  - grafana/dashboards/configmap-dashboard-traefik.yaml
  - grafana/dashboards/configmap-dashboard-coredns.yaml
  - grafana/dashboards/configmap-dashboard-cilium.yaml
  - grafana/dashboards/configmap-dashboard-cnpg.yaml
  - grafana/dashboards/configmap-dashboard-redis.yaml
  - grafana/dashboards/configmap-dashboard-loki.yaml
  - grafana/dashboards/configmap-dashboard-loki-stack.yaml
  - grafana/dashboards/configmap-dashboard-alloy.yaml
  - grafana/dashboards/configmap-dashboard-oauth2-proxy.yaml
  - grafana/dashboards/configmap-dashboard-cluster-autoscaler.yaml
  # Service aliases
  - prometheus-service-alias.yaml
  - alertmanager-service-alias.yaml
  # PrometheusRules + ServiceMonitors
  - prometheus-rules/
  - service-monitors/
```

### Step 3: Validate kustomize build

```bash
kustomize build services/monitoring-stack/
```

### Step 4: Commit

```bash
git add services/monitoring-stack/prometheus-service-alias.yaml \
       services/monitoring-stack/alertmanager-service-alias.yaml \
       services/monitoring-stack/kustomization.yaml
git commit -m "feat: add service aliases and root kustomization for monitoring-stack"
```

---

## Task 10: Deploy Script (deploy-monitoring.sh)

**Files:**
- Create: `scripts/deploy-monitoring.sh`

### Step 1: Create the deploy script

6 phases:
1. Namespace + Loki + Alloy (kustomize apply)
2. Additional scrape configs Secret
3. kube-prometheus-stack Helm install
4. PrometheusRules + ServiceMonitors (kustomize apply)
5. Gateways + HTTPRoutes + basic-auth Secrets (kustomize apply + basic-auth Secret creation)
6. Verify (deployments up, TLS certs issued)

Sources the same utils modules as deploy-pki-secrets.sh plus basic-auth.sh.

CLI: `--phase N`, `--from N`, `--to N`, `--validate`, `-h/--help`

Helm chart: `prometheus-community/kube-prometheus-stack` with version pinned.

Add `HELM_CHART_PROMETHEUS_STACK` and `HELM_REPO_PROMETHEUS_STACK` env vars for OCI override.

### Step 2: ShellCheck clean

```bash
shellcheck scripts/deploy-monitoring.sh
```

### Step 3: Commit

```bash
git add scripts/deploy-monitoring.sh
git commit -m "feat: add deploy-monitoring.sh orchestrator (6 phases)"
```

---

## Task 11: MANIFEST.yaml + README

**Files:**
- Create: `services/monitoring-stack/MANIFEST.yaml`
- Create: `services/monitoring-stack/README.md`

### Step 1: Create MANIFEST.yaml

List all Helm charts, images (kube-prometheus-stack defaults + Loki + Alloy), and Kustomize resources.

### Step 2: Create README.md

Architecture overview, deployment instructions, dashboard list, alert groups, verify commands.

### Step 3: Commit

```bash
git add services/monitoring-stack/MANIFEST.yaml services/monitoring-stack/README.md
git commit -m "docs: add monitoring-stack MANIFEST.yaml and README"
```

---

## Task 12: Update .env.example + subst.sh

**Files:**
- Modify: `scripts/.env.example` — add `GRAFANA_ADMIN_PASSWORD`, `HELM_CHART_PROMETHEUS_STACK`, `HELM_REPO_PROMETHEUS_STACK`
- Modify: `scripts/utils/subst.sh` — add `CHANGEME_GRAFANA_ADMIN_PASSWORD` substitution

### Step 1: Update .env.example

Add:
```bash
# Grafana admin password (required for monitoring bundle)
GRAFANA_ADMIN_PASSWORD=""

# Prometheus stack Helm chart (override for OCI)
# HELM_CHART_PROMETHEUS_STACK="oci://harbor.example.com/charts/kube-prometheus-stack"
# HELM_REPO_PROMETHEUS_STACK="oci://harbor.example.com/charts"
```

### Step 2: Update subst.sh

Add `CHANGEME_GRAFANA_ADMIN_PASSWORD` to `_subst_changeme()`:
```bash
-e "s|CHANGEME_GRAFANA_ADMIN_PASSWORD|${GRAFANA_ADMIN_PASSWORD}|g" \
```

### Step 3: Commit

```bash
git add scripts/.env.example scripts/utils/subst.sh
git commit -m "feat: add Grafana password and prometheus-stack chart to env config"
```

---

## Task 13: Validation Pass + Security Scrub

### Step 1: ShellCheck all scripts

```bash
shellcheck scripts/deploy-monitoring.sh scripts/utils/*.sh
```

### Step 2: Kustomize build

```bash
kustomize build services/monitoring-stack/
```

### Step 3: yamllint

```bash
find services/monitoring-stack/ -name '*.yaml' -not -name '*dashboard*' \
  | xargs yamllint -c .github/linters/.yamllint.yml
```

### Step 4: Security grep

```bash
grep -rn "aegis\|/home/rocky\|derhornspieler" services/monitoring-stack/ scripts/deploy-monitoring.sh
```
Expected: zero matches.

### Step 5: Fix any issues, commit

```bash
git add -A
git commit -m "fix: resolve validation issues in monitoring bundle"
```

---

## Task 14: Push and Monitor CI

### Step 1: Push

```bash
git push origin main
```

### Step 2: Monitor CI

```bash
gh run watch --exit-status
```

### Step 3: Fix any CI failures
