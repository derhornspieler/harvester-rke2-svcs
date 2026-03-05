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

# Keycloak defaults
KC_REALM="${KC_REALM:-platform}"
export KC_REALM

# CNPG operator Helm chart
HELM_CHART_CNPG="${HELM_CHART_CNPG:-cnpg/cloudnative-pg}"
HELM_REPO_CNPG="${HELM_REPO_CNPG:-https://cloudnative-pg.github.io/charts}"

# Vault init file
VAULT_INIT_FILE="${VAULT_INIT_FILE:-${REPO_ROOT}/vault-init.json}"

# CLI Parsing
PHASE_FROM=1
PHASE_TO=8
VALIDATE_ONLY=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Deploy Keycloak identity provider with CNPG PostgreSQL, OAuth2-proxy, and monitoring.

Options:
  --phase N       Run only phase N
  --from N        Start from phase N (default: 1)
  --to N          Stop after phase N (default: 8)
  --validate      Health check all components (no changes)
  -h, --help      Show this help

Phases:
  1  Shared Data Svc     CNPG operator + MinIO (skip if exists)
  2  Namespaces           Create keycloak, database namespaces
  3  ESO ExternalSecrets  Apply ExternalSecrets for Keycloak and PostgreSQL
  4  PostgreSQL CNPG      HA cluster (3 instances), scheduled backup
  5  Keycloak             RBAC, services, deployment, health check
  6  Gateway + HPA        Gateway, HTTPRoute, HPA, TLS verification
  7  OAuth2-proxy         External secrets, deployments, middleware CRDs
  8  Monitoring + Verify  Dashboards, alerts, ServiceMonitors
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
  start_phase "Validation: Keycloak Health Check"

  log_info "Checking keycloak deployment..."
  if kubectl -n keycloak get deployment keycloak \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null; then
    echo " replica(s) ready"
  else
    log_error "keycloak deployment not found"
  fi

  log_info "Checking CNPG PostgreSQL pods..."
  if kubectl -n database get pods -l "cnpg.io/cluster=keycloak-pg,role=primary" \
    --no-headers 2>/dev/null | grep -q "Running"; then
    log_ok "CNPG keycloak-pg primary is running"
  else
    log_error "CNPG keycloak-pg primary not found or not running"
  fi

  log_info "Checking TLS secret..."
  if kubectl -n keycloak get secret "keycloak-${DOMAIN_DASHED}-tls" &>/dev/null; then
    log_ok "TLS secret keycloak-${DOMAIN_DASHED}-tls exists"
  else
    log_warn "TLS secret keycloak-${DOMAIN_DASHED}-tls not found"
  fi

  end_phase "Validation: Keycloak Health Check"
  exit 0
fi

# Phase 1: Shared Data Services (CNPG operator + MinIO)
if [[ $PHASE_FROM -le 1 && $PHASE_TO -ge 1 ]]; then
  start_phase "Phase 1: Shared Data Services"

  # Install CNPG operator (skip if CRD already exists)
  if ! kubectl get crd clusters.postgresql.cnpg.io &>/dev/null; then
    log_info "Installing CloudNativePG operator..."
    helm_repo_add cnpg "$HELM_REPO_CNPG"
    helm_install_if_needed cnpg "$HELM_CHART_CNPG" cnpg-system \
      --version 0.23.0 \
      --set monitoring.podMonitorEnabled=true \
      --set nodeSelector.workload-type=general \
      --wait --timeout 5m
    wait_for_deployment cnpg-system cnpg-cloudnative-pg 300s
  else
    log_info "CNPG operator CRD already exists, skipping install"
  fi

  # Deploy MinIO (shared object storage for CNPG backups)
  kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -
  if ! kubectl -n minio get deployment minio &>/dev/null; then
    log_info "Deploying MinIO..."
    kubectl apply -f "${REPO_ROOT}/services/harbor/minio/pvc.yaml"
    kubectl apply -f "${REPO_ROOT}/services/harbor/minio/deployment.yaml"
    kubectl apply -f "${REPO_ROOT}/services/harbor/minio/service.yaml"
    wait_for_deployment minio minio 300s

    # Create buckets needed by CNPG
    log_info "Creating MinIO buckets for CNPG backups..."
    kube_apply_subst "${REPO_ROOT}/services/harbor/minio/job-create-buckets.yaml"
  else
    log_info "MinIO already deployed, skipping"
  fi

  end_phase "Phase 1: Shared Data Services"
fi

# Phase 2: Namespaces
if [[ $PHASE_FROM -le 2 && $PHASE_TO -ge 2 ]]; then
  start_phase "Phase 2: Namespaces"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/namespace.yaml"
  kubectl create namespace database --dry-run=client -o yaml | kubectl apply -f -
  end_phase "Phase 2: Namespaces"
fi

# Phase 3: ESO ExternalSecrets
if [[ $PHASE_FROM -le 3 && $PHASE_TO -ge 3 ]]; then
  start_phase "Phase 3: ESO ExternalSecrets"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/keycloak/external-secret.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/postgres/external-secret.yaml"

  # Wait for secrets to sync
  log_info "Waiting for ExternalSecrets to sync..."
  sleep 10
  for secret in keycloak-admin-secret:keycloak keycloak-postgres-secret:keycloak \
    keycloak-pg-credentials:database; do
    local_name="${secret%%:*}"
    local_ns="${secret##*:}"
    if kubectl -n "$local_ns" get secret "$local_name" &>/dev/null; then
      log_ok "Secret ${local_name} synced in ${local_ns}"
    else
      log_warn "Secret ${local_name} not yet synced in ${local_ns} (ESO may still be reconciling)"
    fi
  done

  end_phase "Phase 3: ESO ExternalSecrets"
fi

# Phase 4: PostgreSQL CNPG
if [[ $PHASE_FROM -le 4 && $PHASE_TO -ge 4 ]]; then
  start_phase "Phase 4: PostgreSQL CNPG"
  kube_apply_subst "${REPO_ROOT}/services/keycloak/postgres/keycloak-pg-cluster.yaml"

  log_info "Waiting for CNPG primary to be ready (this may take several minutes)..."
  wait_for_pods_ready database "cnpg.io/cluster=keycloak-pg,role=primary" 600

  kubectl apply -f "${REPO_ROOT}/services/keycloak/postgres/keycloak-pg-scheduled-backup.yaml"
  end_phase "Phase 4: PostgreSQL CNPG"
fi

# Phase 5: Keycloak
if [[ $PHASE_FROM -le 5 && $PHASE_TO -ge 5 ]]; then
  start_phase "Phase 5: Keycloak"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/keycloak/rbac.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/keycloak/service.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/keycloak/service-headless.yaml"
  kube_apply_subst "${REPO_ROOT}/services/keycloak/keycloak/deployment.yaml"
  wait_for_deployment keycloak keycloak 600s

  # Health check
  log_info "Verifying Keycloak health..."
  kubectl exec -n keycloak deploy/keycloak -- curl -sf http://localhost:8080/realms/master > /dev/null \
    || log_warn "Keycloak master realm not yet responding (may need a moment)"

  end_phase "Phase 5: Keycloak"
fi

# Phase 6: Gateway + HTTPRoute + HPA
if [[ $PHASE_FROM -le 6 && $PHASE_TO -ge 6 ]]; then
  start_phase "Phase 6: Gateway + HTTPRoute + HPA"
  kube_apply_subst "${REPO_ROOT}/services/keycloak/gateway.yaml"
  kube_apply_subst "${REPO_ROOT}/services/keycloak/httproute.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/keycloak/hpa.yaml"
  wait_for_tls_secret keycloak "keycloak-${DOMAIN_DASHED}-tls" 300
  end_phase "Phase 6: Gateway + HTTPRoute + HPA"
fi

# Phase 7: OAuth2-proxy
if [[ $PHASE_FROM -le 7 && $PHASE_TO -ge 7 ]]; then
  start_phase "Phase 7: OAuth2-proxy"
  log_info "Applying OAuth2-proxy instances..."
  log_warn "NOTE: Run setup-keycloak.sh BEFORE this phase to create OIDC clients"

  # External secrets for OIDC client credentials
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/external-secret-prometheus.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/external-secret-alertmanager.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/external-secret-hubble.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/external-secret-grafana.yaml"

  # OAuth2-proxy deployments
  kube_apply_subst "${REPO_ROOT}/services/keycloak/oauth2-proxy/prometheus.yaml"
  kube_apply_subst "${REPO_ROOT}/services/keycloak/oauth2-proxy/alertmanager.yaml"
  kube_apply_subst "${REPO_ROOT}/services/keycloak/oauth2-proxy/hubble.yaml"

  # Middleware CRDs
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/middleware-prometheus.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/middleware-alertmanager.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/middleware-hubble.yaml"

  end_phase "Phase 7: OAuth2-proxy"
fi

# Phase 8: Monitoring + Verify
if [[ $PHASE_FROM -le 8 && $PHASE_TO -ge 8 ]]; then
  start_phase "Phase 8: Monitoring + Verify"
  kubectl apply -k "${REPO_ROOT}/services/keycloak/monitoring/"
  # NetworkPolicies
  log_info "Applying NetworkPolicies for Identity services..."
  kubectl apply -f "${REPO_ROOT}/services/keycloak/networkpolicy.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/postgres/networkpolicy.yaml"
  end_phase "Phase 8: Monitoring + Verify"
fi

log_ok "Keycloak deployment complete"
