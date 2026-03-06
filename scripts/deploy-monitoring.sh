#!/usr/bin/env bash
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
  4  Rules + Monitors + Scaling   Apply rules, ServiceMonitors, HPA, VolumeAutoscalers
  5  Gateways + Routes + Auth     Ingress routes, Traefik dashboard, OAuth2-proxy, dashboards
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

  log_info "Checking Traefik dashboard..."
  if kubectl -n kube-system get deployment oauth2-proxy-traefik \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null; then
    echo " replica(s) ready"
  else
    log_error "Traefik dashboard OAuth2-proxy not found"
  fi

  log_info "Checking TLS secrets..."
  for secret in "grafana-${DOMAIN_DASHED}-tls" "prometheus-${DOMAIN_DASHED}-tls" "alertmanager-${DOMAIN_DASHED}-tls"; do
    if kubectl -n monitoring get secret "$secret" &>/dev/null; then
      log_ok "TLS secret ${secret} exists"
    else
      log_warn "TLS secret ${secret} not found"
    fi
  done
  # Traefik dashboard TLS is in kube-system (Gateway lives there)
  if kubectl -n kube-system get secret "traefik-${DOMAIN_DASHED}-tls" &>/dev/null; then
    log_ok "TLS secret traefik-${DOMAIN_DASHED}-tls exists (kube-system)"
  else
    log_warn "TLS secret traefik-${DOMAIN_DASHED}-tls not found (kube-system)"
  fi

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

  # Create prerequisites that Grafana needs before helm install
  # 1. vault-root-ca ConfigMap (Grafana mounts this for OIDC TLS verification)
  ROOT_CA_CERT="${ROOT_CA_CERT:-${REPO_ROOT}/services/pki/roots/root-ca.pem}"
  if [[ -f "$ROOT_CA_CERT" ]]; then
    log_info "Creating vault-root-ca ConfigMap..."
    kubectl create configmap vault-root-ca \
      --namespace=monitoring \
      --from-file=ca.crt="$ROOT_CA_CERT" \
      --dry-run=client -o yaml | kubectl apply -f -
  else
    log_warn "Root CA cert not found at ${ROOT_CA_CERT} — Grafana OIDC TLS verification may fail"
  fi

  # 2. grafana-oidc-secret placeholder (real secret comes from ESO after setup-keycloak.sh)
  if ! kubectl -n monitoring get secret grafana-oidc-secret &>/dev/null; then
    log_info "Creating placeholder grafana-oidc-secret (will be replaced by ESO after Keycloak setup)..."
    kubectl create secret generic grafana-oidc-secret \
      --namespace=monitoring \
      --from-literal=client-secret=placeholder-will-be-replaced-by-eso \
      --dry-run=client -o yaml | kubectl apply -f -
  fi

  # 3. Grafana PostgreSQL backend (CNPG cluster in database namespace)
  VAULT_INIT_FILE="${VAULT_INIT_FILE:-${REPO_ROOT}/vault-init.json}"
  if [[ -f "$VAULT_INIT_FILE" ]]; then
    root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")

    # Seed Vault with Grafana DB credentials (idempotent)
    GRAFANA_DB_USER="grafana"
    GRAFANA_DB_PASS=$(vault_get_or_generate "$root_token" \
      "kv/services/database/grafana-pg" "password" "openssl rand -base64 24")
    vault_exec "$root_token" kv put kv/services/database/grafana-pg \
      username="$GRAFANA_DB_USER" \
      password="$GRAFANA_DB_PASS"
    log_ok "Grafana DB credentials seeded in Vault"

    # Apply ExternalSecrets (creates secrets in both database and monitoring namespaces)
    kubectl apply -f "${REPO_ROOT}/services/monitoring-stack/grafana/postgres/external-secret.yaml"
    log_info "Waiting for grafana-pg-credentials ExternalSecret to sync..."
    kubectl wait --for=condition=Ready externalsecret/grafana-pg-credentials \
      -n database --timeout=120s
    kubectl wait --for=condition=Ready externalsecret/grafana-db-secret \
      -n monitoring --timeout=120s
    log_ok "Grafana DB ExternalSecrets synced"

    # Apply CNPG Cluster (uses CHANGEME_MINIO_ENDPOINT substitution)
    kube_apply_subst "${REPO_ROOT}/services/monitoring-stack/grafana/postgres/grafana-pg-cluster.yaml"
    kubectl apply -f "${REPO_ROOT}/services/monitoring-stack/grafana/postgres/grafana-pg-scheduled-backup.yaml"

    # Wait for CNPG cluster to become ready
    log_info "Waiting for grafana-pg CNPG cluster to become ready..."
    kubectl wait --for=condition=Ready clusters.postgresql.cnpg.io/grafana-pg -n database --timeout=300s
    log_ok "Grafana PostgreSQL cluster ready"
  else
    log_warn "Vault init file not found — skipping Grafana PostgreSQL setup"
  fi

  helm_repo_add prometheus-community "$HELM_REPO_PROMETHEUS_STACK"
  # Substitute CHANGEME tokens in values file before passing to helm
  _prom_values=$(mktemp /tmp/prom-values.XXXXXX.yaml)
  trap 'rm -f "$_prom_values"' EXIT
  chmod 600 "$_prom_values"
  _subst_changeme < "${REPO_ROOT}/services/monitoring-stack/helm/kube-prometheus-stack-values.yaml" > "$_prom_values"
  helm_install_if_needed kube-prometheus-stack "$HELM_CHART_PROMETHEUS_STACK" monitoring \
    --version 72.6.2 \
    -f "$_prom_values" \
    --wait --timeout 10m
  rm -f "$_prom_values"
  wait_for_deployment monitoring kube-prometheus-stack-operator 300s
  end_phase "Phase 3: kube-prometheus-stack Helm Install"
fi

# Phase 4: PrometheusRules + ServiceMonitors
if [[ $PHASE_FROM -le 4 && $PHASE_TO -ge 4 ]]; then
  start_phase "Phase 4: Rules + Monitors + Scaling"
  kubectl apply -k "${REPO_ROOT}/services/monitoring-stack/prometheus-rules/"
  kubectl apply -k "${REPO_ROOT}/services/monitoring-stack/service-monitors/"
  # Also apply per-service monitoring from Bundle 1
  kubectl apply -k "${REPO_ROOT}/services/vault/monitoring/"
  kubectl apply -k "${REPO_ROOT}/services/cert-manager/monitoring/"
  kubectl apply -k "${REPO_ROOT}/services/external-secrets/monitoring/"
  # Grafana HPA
  kubectl apply -f "${REPO_ROOT}/services/monitoring-stack/grafana/hpa.yaml"
  # Volume autoscalers (PVC auto-expansion)
  kubectl apply -f "${REPO_ROOT}/services/monitoring-stack/volume-autoscalers.yaml"
  end_phase "Phase 4: Rules + Monitors + Scaling"
fi

# Phase 5: Gateways + HTTPRoutes + OAuth2-proxy auth
if [[ $PHASE_FROM -le 5 && $PHASE_TO -ge 5 ]]; then
  start_phase "Phase 5: Gateways + HTTPRoutes + OAuth2-proxy Auth"

  # Grafana admin password from Vault (basic-auth no longer used for Prometheus/Alertmanager)
  VAULT_INIT_FILE="${VAULT_INIT_FILE:-${REPO_ROOT}/vault-init.json}"
  if [[ -f "$VAULT_INIT_FILE" ]]; then
    root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")
    GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-$(vault_get_or_generate "$root_token" \
      "kv/services/monitoring" "grafana-admin-password" "openssl rand -base64 24")}"

    vault_exec "$root_token" kv put kv/services/monitoring \
      grafana-admin-password="$GRAFANA_ADMIN_PASSWORD"
  else
    log_warn "Vault init file not found — using .env passwords (not stored in Vault)"
  fi

  # Apply gateways and routes (need domain substitution)
  # Auth is handled by OAuth2-proxy ForwardAuth middlewares (deployed in setup-keycloak.sh)
  kube_apply_subst "${REPO_ROOT}/services/monitoring-stack/prometheus/gateway.yaml"
  kube_apply_subst "${REPO_ROOT}/services/monitoring-stack/prometheus/httproute.yaml"
  kube_apply_subst "${REPO_ROOT}/services/monitoring-stack/alertmanager/gateway.yaml"
  kube_apply_subst "${REPO_ROOT}/services/monitoring-stack/alertmanager/httproute.yaml"
  kube_apply_subst "${REPO_ROOT}/services/monitoring-stack/grafana/gateway.yaml"
  kube_apply_subst "${REPO_ROOT}/services/monitoring-stack/grafana/httproute.yaml"
  # Service aliases
  kubectl apply -f "${REPO_ROOT}/services/monitoring-stack/prometheus-service-alias.yaml"
  kubectl apply -f "${REPO_ROOT}/services/monitoring-stack/alertmanager-service-alias.yaml"

  # Traefik Dashboard — enable API + protect with OAuth2-proxy
  log_info "Enabling Traefik dashboard with OAuth2-proxy auth..."
  kubectl apply -f "${REPO_ROOT}/services/traefik-dashboard/helmchartconfig.yaml"
  kubectl apply -f "${REPO_ROOT}/services/traefik-dashboard/external-secret.yaml"
  kubectl apply -f "${REPO_ROOT}/services/traefik-dashboard/dashboard-service.yaml"
  kubectl apply -f "${REPO_ROOT}/services/traefik-dashboard/middleware.yaml"
  kube_apply_subst "${REPO_ROOT}/services/traefik-dashboard/oauth2-proxy.yaml"
  kube_apply_subst "${REPO_ROOT}/services/traefik-dashboard/gateway.yaml"
  kube_apply_subst "${REPO_ROOT}/services/traefik-dashboard/httproute.yaml"

  # Apply dashboards (some contain CHANGEME_DOMAIN tokens)
  for f in "${REPO_ROOT}"/services/monitoring-stack/grafana/dashboards/configmap-dashboard-*.yaml; do
    kube_apply_subst "$f"
  done
  end_phase "Phase 5: Gateways + HTTPRoutes + OAuth2-proxy Auth"
fi

# Phase 6: Verify
if [[ $PHASE_FROM -le 6 && $PHASE_TO -ge 6 ]]; then
  start_phase "Phase 6: Verify"
  wait_for_deployment monitoring grafana 300s
  wait_for_pods_ready monitoring "app.kubernetes.io/name=prometheus" 300
  wait_for_tls_secret monitoring "grafana-${DOMAIN_DASHED}-tls" 300
  wait_for_tls_secret monitoring "prometheus-${DOMAIN_DASHED}-tls" 300
  wait_for_tls_secret monitoring "alertmanager-${DOMAIN_DASHED}-tls" 300
  wait_for_tls_secret kube-system "traefik-${DOMAIN_DASHED}-tls" 300
  wait_for_deployment kube-system oauth2-proxy-traefik 300s
  end_phase "Phase 6: Verify"
fi

log_ok "Monitoring stack deployment complete"
