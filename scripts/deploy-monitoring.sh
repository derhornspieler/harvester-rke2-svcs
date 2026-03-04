#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source utility modules
source "${SCRIPT_DIR}/utils/log.sh"
source "${SCRIPT_DIR}/utils/helm.sh"
source "${SCRIPT_DIR}/utils/wait.sh"
source "${SCRIPT_DIR}/utils/subst.sh"
source "${SCRIPT_DIR}/utils/basic-auth.sh"

# Load environment
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
fi

# Domain defaults
DOMAIN="${DOMAIN:?DOMAIN must be set}"
DOMAIN_DASHED="${DOMAIN_DASHED:-$(echo "$DOMAIN" | tr '.' '-')}"
DOMAIN_DOT="${DOMAIN_DOT:-${DOMAIN//./-dot-}}"
export DOMAIN DOMAIN_DASHED DOMAIN_DOT

# Helm chart sources (override with oci:// paths for Harbor or private registries)
HELM_CHART_PROMETHEUS_STACK="${HELM_CHART_PROMETHEUS_STACK:-prometheus-community/kube-prometheus-stack}"
HELM_REPO_PROMETHEUS_STACK="${HELM_REPO_PROMETHEUS_STACK:-https://prometheus-community.github.io/helm-charts}"

# CLI Parsing
PHASE_FROM=1
PHASE_TO=6
VALIDATE_ONLY=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Deploy monitoring bundle (Loki + Alloy + kube-prometheus-stack + Grafana).

Options:
  --phase N       Run only phase N
  --from N        Start from phase N (default: 1)
  --to N          Stop after phase N (default: 6)
  --validate      Health check all components (no changes)
  -h, --help      Show this help

Phases:
  1  Namespace + Loki + Alloy     Create NS, deploy Loki and Alloy
  2  Scrape Configs Secret        Additional Prometheus scrape configs
  3  kube-prometheus-stack         Helm install (Prometheus, Grafana, Alertmanager)
  4  PrometheusRules + Monitors   Apply rules, ServiceMonitors, per-service monitoring
  5  Gateways + Routes + Auth     Ingress routes, basic-auth, dashboards
  6  Verify                        Wait for all components to become ready
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)     PHASE_FROM="$2"; PHASE_TO="$2"; shift 2 ;;
    --from)      PHASE_FROM="$2"; shift 2 ;;
    --to)        PHASE_TO="$2"; shift 2 ;;
    --validate)  VALIDATE_ONLY=true; shift ;;
    -h|--help)   usage ;;
    *)           die "Unknown option: $1" ;;
  esac
done

# Validation mode
if [[ "$VALIDATE_ONLY" == "true" ]]; then
  start_phase "Validation: Monitoring Health Check"

  log_info "Checking Prometheus operator..."
  if kubectl -n monitoring get deployment kube-prometheus-stack-operator \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null; then
    echo " replica(s) ready"
  else
    log_error "Prometheus operator not found"
  fi

  log_info "Checking Grafana..."
  if kubectl -n monitoring get deployment grafana \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null; then
    echo " replica(s) ready"
  else
    log_error "Grafana not found"
  fi

  log_info "Checking Loki..."
  if kubectl -n monitoring get statefulset loki \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null; then
    echo " replica(s) ready"
  else
    log_error "Loki not found"
  fi

  log_info "Checking Alertmanager..."
  if kubectl -n monitoring get statefulset alertmanager-kube-prometheus-stack-alertmanager \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null; then
    echo " replica(s) ready"
  else
    log_error "Alertmanager not found"
  fi

  log_info "Checking TLS secrets..."
  for secret in "grafana-${DOMAIN_DASHED}-tls" "prometheus-${DOMAIN_DASHED}-tls" "alertmanager-${DOMAIN_DASHED}-tls"; do
    if kubectl -n monitoring get secret "$secret" &>/dev/null; then
      log_ok "TLS secret ${secret} exists"
    else
      log_warn "TLS secret ${secret} not found"
    fi
  done

  end_phase "Validation: Monitoring Health Check"
  exit 0
fi

# Phase 1: Namespace + Loki + Alloy
if [[ $PHASE_FROM -le 1 && $PHASE_TO -ge 1 ]]; then
  start_phase "Phase 1: Namespace + Loki + Alloy"
  kubectl apply -f "${REPO_ROOT}/services/monitoring-stack/namespace.yaml"
  kubectl apply -f "${REPO_ROOT}/services/monitoring-stack/loki/rbac.yaml"
  kubectl apply -f "${REPO_ROOT}/services/monitoring-stack/loki/configmap.yaml"
  kubectl apply -f "${REPO_ROOT}/services/monitoring-stack/loki/statefulset.yaml"
  kubectl apply -f "${REPO_ROOT}/services/monitoring-stack/loki/service.yaml"
  kubectl apply -f "${REPO_ROOT}/services/monitoring-stack/alloy/rbac.yaml"
  kubectl apply -f "${REPO_ROOT}/services/monitoring-stack/alloy/configmap.yaml"
  kubectl apply -f "${REPO_ROOT}/services/monitoring-stack/alloy/daemonset.yaml"
  kubectl apply -f "${REPO_ROOT}/services/monitoring-stack/alloy/service.yaml"
  wait_for_pods_ready monitoring "app=loki" 300
  end_phase "Phase 1: Namespace + Loki + Alloy"
fi

# Phase 2: Additional scrape configs Secret
if [[ $PHASE_FROM -le 2 && $PHASE_TO -ge 2 ]]; then
  start_phase "Phase 2: Additional Scrape Configs Secret"
  log_info "Creating additional-scrape-configs Secret..."
  kubectl create secret generic additional-scrape-configs \
    --namespace=monitoring \
    --from-file=scrape-configs.yaml="${REPO_ROOT}/services/monitoring-stack/helm/additional-scrape-configs.yaml" \
    --dry-run=client -o yaml | kubectl apply -f -
  end_phase "Phase 2: Additional Scrape Configs Secret"
fi

# Phase 3: kube-prometheus-stack Helm install
if [[ $PHASE_FROM -le 3 && $PHASE_TO -ge 3 ]]; then
  start_phase "Phase 3: kube-prometheus-stack Helm Install"
  helm_repo_add prometheus-community "$HELM_REPO_PROMETHEUS_STACK"
  # Substitute CHANGEME tokens in values file before passing to helm
  _subst_changeme < "${REPO_ROOT}/services/monitoring-stack/helm/kube-prometheus-stack-values.yaml" > /tmp/prom-values.yaml
  helm_install_if_needed kube-prometheus-stack "$HELM_CHART_PROMETHEUS_STACK" monitoring \
    --version 72.6.2 \
    -f /tmp/prom-values.yaml \
    --wait --timeout 10m
  rm -f /tmp/prom-values.yaml
  wait_for_deployment monitoring kube-prometheus-stack-operator 300s
  end_phase "Phase 3: kube-prometheus-stack Helm Install"
fi

# Phase 4: PrometheusRules + ServiceMonitors
if [[ $PHASE_FROM -le 4 && $PHASE_TO -ge 4 ]]; then
  start_phase "Phase 4: PrometheusRules + ServiceMonitors"
  kubectl apply -k "${REPO_ROOT}/services/monitoring-stack/prometheus-rules/"
  kubectl apply -k "${REPO_ROOT}/services/monitoring-stack/service-monitors/"
  # Also apply per-service monitoring from Bundle 1
  kubectl apply -k "${REPO_ROOT}/services/vault/monitoring/"
  kubectl apply -k "${REPO_ROOT}/services/cert-manager/monitoring/"
  kubectl apply -k "${REPO_ROOT}/services/external-secrets/monitoring/"
  end_phase "Phase 4: PrometheusRules + ServiceMonitors"
fi

# Phase 5: Gateways + HTTPRoutes + basic-auth
if [[ $PHASE_FROM -le 5 && $PHASE_TO -ge 5 ]]; then
  start_phase "Phase 5: Gateways + HTTPRoutes + Basic Auth"
  # Create basic-auth secrets (credentials from environment or defaults)
  create_basic_auth_secret monitoring basic-auth-prometheus \
    "${PROM_BASIC_AUTH_USER:-admin}" "${PROM_BASIC_AUTH_PASS:?Set PROM_BASIC_AUTH_PASS in .env}"
  create_basic_auth_secret monitoring basic-auth-alertmanager \
    "${AM_BASIC_AUTH_USER:-admin}" "${AM_BASIC_AUTH_PASS:?Set AM_BASIC_AUTH_PASS in .env}"
  # Apply gateways and routes (need domain substitution)
  kube_apply_subst "${REPO_ROOT}/services/monitoring-stack/prometheus/gateway.yaml"
  kube_apply_subst "${REPO_ROOT}/services/monitoring-stack/prometheus/httproute.yaml"
  kubectl apply -f "${REPO_ROOT}/services/monitoring-stack/prometheus/basic-auth-middleware.yaml"
  kube_apply_subst "${REPO_ROOT}/services/monitoring-stack/alertmanager/gateway.yaml"
  kube_apply_subst "${REPO_ROOT}/services/monitoring-stack/alertmanager/httproute.yaml"
  kubectl apply -f "${REPO_ROOT}/services/monitoring-stack/alertmanager/basic-auth-middleware.yaml"
  kube_apply_subst "${REPO_ROOT}/services/monitoring-stack/grafana/gateway.yaml"
  kube_apply_subst "${REPO_ROOT}/services/monitoring-stack/grafana/httproute.yaml"
  # Service aliases
  kubectl apply -f "${REPO_ROOT}/services/monitoring-stack/prometheus-service-alias.yaml"
  kubectl apply -f "${REPO_ROOT}/services/monitoring-stack/alertmanager-service-alias.yaml"
  # Apply dashboards
  for f in "${REPO_ROOT}"/services/monitoring-stack/grafana/dashboards/configmap-dashboard-*.yaml; do
    kubectl apply -f "$f"
  done
  end_phase "Phase 5: Gateways + HTTPRoutes + Basic Auth"
fi

# Phase 6: Verify
if [[ $PHASE_FROM -le 6 && $PHASE_TO -ge 6 ]]; then
  start_phase "Phase 6: Verify"
  wait_for_deployment monitoring grafana 300s
  wait_for_pods_ready monitoring "app.kubernetes.io/name=prometheus" 300
  wait_for_tls_secret monitoring "grafana-${DOMAIN_DASHED}-tls" 300
  wait_for_tls_secret monitoring "prometheus-${DOMAIN_DASHED}-tls" 300
  wait_for_tls_secret monitoring "alertmanager-${DOMAIN_DASHED}-tls" 300
  end_phase "Phase 6: Verify"
fi

log_ok "Monitoring stack deployment complete"
