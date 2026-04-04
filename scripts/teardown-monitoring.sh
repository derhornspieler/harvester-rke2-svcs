#!/usr/bin/env bash
# teardown-monitoring.sh — Tear down Bundle 3 (Monitoring: Prometheus, Grafana, Loki, Alloy)
# Reverse of deploy-monitoring.sh: Helm release, Loki/Alloy, Grafana CNPG, Traefik dashboard,
# OAuth2-proxy instances, Vault, namespace.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source utility modules
source "${SCRIPT_DIR}/utils/log.sh"
source "${SCRIPT_DIR}/utils/helm.sh"
source "${SCRIPT_DIR}/utils/wait.sh"
source "${SCRIPT_DIR}/utils/vault.sh"
source "${SCRIPT_DIR}/utils/subst.sh"

# Load environment
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
fi

# Domain defaults
DOMAIN="${DOMAIN:?DOMAIN must be set}"
DOMAIN_DASHED="${DOMAIN_DASHED:-$(echo "$DOMAIN" | tr '.' '-')}"
export DOMAIN DOMAIN_DASHED

# Vault init file
VAULT_INIT_FILE="${VAULT_INIT_FILE:-${REPO_ROOT}/vault-init.json}"

# CLI Parsing
PHASE_FROM=1
PHASE_TO=6
DRY_RUN=false
FORCE=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Tear down Bundle 3: Monitoring (kube-prometheus-stack, Grafana, Loki, Alloy).

Options:
  --phase N       Run only phase N
  --from N        Start from phase N (default: 1)
  --to N          Stop after phase N (default: 6)
  --dry-run       Print what would be done without making changes
  --force         Skip dependency guards
  -h, --help      Show this help

Phases:
  1  Helm release         Delete kube-prometheus-stack Helm release
  2  Loki + Alloy + CNPG  Delete Loki, Alloy, Grafana CNPG cluster
  3  Dashboards + CRDs    Delete Grafana dashboards, ServiceMonitors, PrometheusRules
  4  Vault                Delete Vault secrets, policies for monitoring/OIDC
  5  Traefik dashboard    Delete kube-system OAuth2-proxy, middleware, gateway, routes
  6  PVCs + Namespace     Delete PVCs, monitoring namespace
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)     PHASE_FROM="$2"; PHASE_TO="$2"; shift 2 ;;
    --from)      PHASE_FROM="$2"; shift 2 ;;
    --to)        PHASE_TO="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --force)     FORCE=true; shift ;;
    -h|--help)   usage ;;
    *)           die "Unknown option: $1" ;;
  esac
done

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] $*"
  else
    "$@"
  fi
}

safe_delete() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] kubectl delete $*"
  else
    kubectl delete "$@" 2>/dev/null || true
  fi
}

vault_teardown_exec() {
  local root_token="$1"
  shift
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] vault $*"
  else
    vault_exec "$root_token" "$@" 2>/dev/null || true
  fi
}

# Dependency guard: harbor, argocd, gitlab namespaces must not exist
if [[ "$FORCE" != "true" ]]; then
  for ns in harbor argocd gitlab; do
    if kubectl get namespace "$ns" &>/dev/null; then
      die "Namespace ${ns} still exists. Tear down dependent bundles first or use --force."
    fi
  done
fi

# Phase 1: Delete kube-prometheus-stack Helm release
if [[ $PHASE_FROM -le 1 && $PHASE_TO -ge 1 ]]; then
  start_phase "Phase 1: kube-prometheus-stack Helm Release"

  log_info "Deleting VolumeAutoscalers..."
  safe_delete -f "${REPO_ROOT}/services/monitoring-stack/volume-autoscalers.yaml" --ignore-not-found

  log_info "Deleting Grafana HPA..."
  safe_delete -f "${REPO_ROOT}/services/monitoring-stack/grafana/hpa.yaml" --ignore-not-found

  log_info "Deleting kube-prometheus-stack Helm release..."
  run helm uninstall kube-prometheus-stack -n monitoring --wait --timeout 5m 2>/dev/null || true

  end_phase "Phase 1: kube-prometheus-stack Helm Release"
fi

# Phase 2: Delete Loki, Alloy, Grafana CNPG cluster
if [[ $PHASE_FROM -le 2 && $PHASE_TO -ge 2 ]]; then
  start_phase "Phase 2: Loki + Alloy + Grafana CNPG"

  log_info "Deleting Alloy resources..."
  safe_delete -f "${REPO_ROOT}/services/monitoring-stack/alloy/daemonset.yaml" --ignore-not-found
  safe_delete -f "${REPO_ROOT}/services/monitoring-stack/alloy/service.yaml" --ignore-not-found
  safe_delete -f "${REPO_ROOT}/services/monitoring-stack/alloy/configmap.yaml" --ignore-not-found
  safe_delete -f "${REPO_ROOT}/services/monitoring-stack/alloy/rbac.yaml" --ignore-not-found

  log_info "Deleting Loki resources..."
  safe_delete -f "${REPO_ROOT}/services/monitoring-stack/loki/service.yaml" --ignore-not-found
  safe_delete -f "${REPO_ROOT}/services/monitoring-stack/loki/statefulset.yaml" --ignore-not-found
  safe_delete -f "${REPO_ROOT}/services/monitoring-stack/loki/configmap.yaml" --ignore-not-found
  safe_delete -f "${REPO_ROOT}/services/monitoring-stack/loki/rbac.yaml" --ignore-not-found

  log_info "Deleting Grafana CNPG scheduled backup..."
  safe_delete -f "${REPO_ROOT}/services/monitoring-stack/grafana/postgres/grafana-pg-scheduled-backup.yaml" --ignore-not-found

  log_info "Deleting Grafana CNPG cluster..."
  safe_delete clusters.postgresql.cnpg.io grafana-pg -n database --ignore-not-found

  log_info "Deleting Grafana DB ExternalSecrets..."
  safe_delete externalsecret grafana-pg-credentials -n database --ignore-not-found
  safe_delete externalsecret grafana-db-secret -n monitoring --ignore-not-found

  end_phase "Phase 2: Loki + Alloy + Grafana CNPG"
fi

# Phase 3: Delete Grafana dashboards, ServiceMonitors, PrometheusRules
if [[ $PHASE_FROM -le 3 && $PHASE_TO -ge 3 ]]; then
  start_phase "Phase 3: Dashboards + ServiceMonitors + PrometheusRules"

  log_info "Deleting Grafana dashboards..."
  for f in "${REPO_ROOT}"/services/monitoring-stack/grafana/dashboards/configmap-dashboard-*.yaml; do
    [[ -f "$f" ]] && safe_delete -f "$f" --ignore-not-found
  done

  log_info "Deleting PrometheusRules..."
  safe_delete -k "${REPO_ROOT}/services/monitoring-stack/prometheus-rules/" --ignore-not-found

  log_info "Deleting ServiceMonitors..."
  safe_delete -k "${REPO_ROOT}/services/monitoring-stack/service-monitors/" --ignore-not-found

  log_info "Deleting Bundle 1 monitoring overlays..."
  safe_delete -k "${REPO_ROOT}/services/vault/monitoring/" --ignore-not-found
  safe_delete -k "${REPO_ROOT}/services/cert-manager/monitoring/" --ignore-not-found
  safe_delete -k "${REPO_ROOT}/services/external-secrets/monitoring/" --ignore-not-found

  log_info "Deleting monitoring Gateways, HTTPRoutes, service aliases..."
  safe_delete httproute grafana -n monitoring --ignore-not-found
  safe_delete gateway monitoring -n monitoring --ignore-not-found
  safe_delete httproute prometheus -n monitoring --ignore-not-found
  safe_delete gateway prometheus -n monitoring --ignore-not-found
  safe_delete httproute alertmanager -n monitoring --ignore-not-found
  safe_delete gateway alertmanager -n monitoring --ignore-not-found
  safe_delete -f "${REPO_ROOT}/services/monitoring-stack/prometheus-service-alias.yaml" --ignore-not-found
  safe_delete -f "${REPO_ROOT}/services/monitoring-stack/alertmanager-service-alias.yaml" --ignore-not-found

  log_info "Deleting additional-scrape-configs Secret..."
  safe_delete secret additional-scrape-configs -n monitoring --ignore-not-found

  end_phase "Phase 3: Dashboards + ServiceMonitors + PrometheusRules"
fi

# Phase 4: Delete Vault secrets and policies
if [[ $PHASE_FROM -le 4 && $PHASE_TO -ge 4 ]]; then
  start_phase "Phase 4: Vault Secrets + Policies"

  if [[ -f "$VAULT_INIT_FILE" ]]; then
    root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")

    log_info "Deleting Vault KV secrets for monitoring..."
    for path in kv/services/monitoring kv/services/database/grafana-pg \
      kv/oidc/prometheus-oidc kv/oidc/alertmanager-oidc kv/oidc/grafana \
      kv/oidc/hubble-oidc kv/oidc/traefik-oidc; do
      vault_teardown_exec "$root_token" kv metadata delete "$path"
    done

    log_info "Deleting Vault policy eso-monitoring..."
    vault_teardown_exec "$root_token" policy delete "eso-monitoring"
    log_info "Deleting Vault K8s auth role eso-monitoring..."
    vault_teardown_exec "$root_token" delete "auth/kubernetes/role/eso-monitoring"

    log_info "Deleting Vault policy eso-kube-system..."
    vault_teardown_exec "$root_token" policy delete "eso-kube-system"
    log_info "Deleting Vault K8s auth role eso-kube-system..."
    vault_teardown_exec "$root_token" delete "auth/kubernetes/role/eso-kube-system"
  else
    log_warn "Vault init file not found — skipping Vault cleanup"
  fi

  log_info "Deleting SecretStores..."
  safe_delete secretstore vault-backend -n monitoring --ignore-not-found
  safe_delete secretstore vault-backend -n kube-system --ignore-not-found

  end_phase "Phase 4: Vault Secrets + Policies"
fi

# Phase 5: Delete Traefik dashboard resources (kube-system)
if [[ $PHASE_FROM -le 5 && $PHASE_TO -ge 5 ]]; then
  start_phase "Phase 5: Traefik Dashboard (kube-system)"

  log_info "Deleting Traefik dashboard resources..."
  safe_delete httproute traefik-dashboard -n kube-system --ignore-not-found
  safe_delete gateway traefik-dashboard -n kube-system --ignore-not-found
  safe_delete middleware oauth2-proxy-traefik -n kube-system --ignore-not-found

  log_info "Deleting Traefik OAuth2-proxy deployment and service..."
  safe_delete deployment oauth2-proxy-traefik -n kube-system --ignore-not-found
  safe_delete service oauth2-proxy-traefik -n kube-system --ignore-not-found

  log_info "Deleting Traefik dashboard service..."
  safe_delete service traefik-dashboard -n kube-system --ignore-not-found

  log_info "Deleting Traefik dashboard ExternalSecret..."
  safe_delete externalsecret oauth2-proxy-traefik -n kube-system --ignore-not-found

  log_info "Deleting OAuth2-proxy ExternalSecrets in monitoring namespace..."
  safe_delete externalsecret oauth2-proxy-prometheus -n monitoring --ignore-not-found
  safe_delete externalsecret oauth2-proxy-alertmanager -n monitoring --ignore-not-found
  safe_delete externalsecret grafana-oidc-secret -n monitoring --ignore-not-found

  log_info "Deleting OAuth2-proxy ExternalSecret in kube-system (hubble)..."
  safe_delete externalsecret oauth2-proxy-hubble -n kube-system --ignore-not-found

  log_info "Deleting OAuth2-proxy deployments in monitoring..."
  safe_delete deployment oauth2-proxy-prometheus -n monitoring --ignore-not-found
  safe_delete service oauth2-proxy-prometheus -n monitoring --ignore-not-found
  safe_delete deployment oauth2-proxy-alertmanager -n monitoring --ignore-not-found
  safe_delete service oauth2-proxy-alertmanager -n monitoring --ignore-not-found

  log_info "Deleting OAuth2-proxy middlewares in monitoring..."
  safe_delete middleware oauth2-proxy-prometheus -n monitoring --ignore-not-found
  safe_delete middleware oauth2-proxy-alertmanager -n monitoring --ignore-not-found

  log_info "Deleting Hubble OAuth2-proxy in kube-system..."
  safe_delete deployment oauth2-proxy-hubble -n kube-system --ignore-not-found
  safe_delete service oauth2-proxy-hubble -n kube-system --ignore-not-found
  safe_delete middleware oauth2-proxy-hubble -n kube-system --ignore-not-found

  # Note: HelmChartConfig rke2-traefik is NOT deleted — it configures the system Traefik
  log_warn "HelmChartConfig rke2-traefik in kube-system preserved (system component)"

  end_phase "Phase 5: Traefik Dashboard (kube-system)"
fi

# Phase 6: Delete PVCs and namespace
if [[ $PHASE_FROM -le 6 && $PHASE_TO -ge 6 ]]; then
  start_phase "Phase 6: PVCs + Namespace"

  log_info "Deleting PVCs in monitoring namespace..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] kubectl delete pvc --all -n monitoring"
  else
    kubectl delete pvc --all -n monitoring --wait=false 2>/dev/null || true
  fi

  log_info "Deleting monitoring namespace..."
  safe_delete namespace monitoring --ignore-not-found --wait=true --timeout=120s

  end_phase "Phase 6: PVCs + Namespace"
fi

log_ok "Bundle 3 (Monitoring) teardown complete"
