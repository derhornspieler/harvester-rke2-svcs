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

# Vault init file
VAULT_INIT_FILE="${VAULT_INIT_FILE:-${REPO_ROOT}/vault-init.json}"

# CLI Parsing
PHASE_FROM=1
PHASE_TO=7
VALIDATE_ONLY=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Deploy Keycloak identity provider with CNPG PostgreSQL, OAuth2-proxy, and monitoring.

Options:
  --phase N       Run only phase N
  --from N        Start from phase N (default: 1)
  --to N          Stop after phase N (default: 7)
  --validate      Health check all components (no changes)
  -h, --help      Show this help

Phases:
  1  Namespaces           Create keycloak, database namespaces
  2  ESO ExternalSecrets  Apply ExternalSecrets for Keycloak and PostgreSQL
  3  PostgreSQL CNPG      HA cluster (3 instances), scheduled backup
  4  Keycloak             RBAC, services, deployment, health check
  5  Gateway + HPA        Gateway, HTTPRoute, HPA, TLS verification
  6  OAuth2-proxy         External secrets, deployments, middleware CRDs
  7  Monitoring + Verify  Dashboards, alerts, ServiceMonitors
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

# Phase 1: Namespaces
if [[ $PHASE_FROM -le 1 && $PHASE_TO -ge 1 ]]; then
  start_phase "Phase 1: Namespaces"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/namespace.yaml"
  kubectl create namespace database --dry-run=client -o yaml | kubectl apply -f -
  end_phase "Phase 1: Namespaces"
fi

# Phase 2: ESO ExternalSecrets
if [[ $PHASE_FROM -le 2 && $PHASE_TO -ge 2 ]]; then
  start_phase "Phase 2: ESO ExternalSecrets"
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

  end_phase "Phase 2: ESO ExternalSecrets"
fi

# Phase 3: PostgreSQL CNPG
if [[ $PHASE_FROM -le 3 && $PHASE_TO -ge 3 ]]; then
  start_phase "Phase 3: PostgreSQL CNPG"
  kube_apply_subst "${REPO_ROOT}/services/keycloak/postgres/keycloak-pg-cluster.yaml"

  log_info "Waiting for CNPG primary to be ready (this may take several minutes)..."
  wait_for_pods_ready database "cnpg.io/cluster=keycloak-pg,role=primary" 600

  kubectl apply -f "${REPO_ROOT}/services/keycloak/postgres/keycloak-pg-scheduled-backup.yaml"
  end_phase "Phase 3: PostgreSQL CNPG"
fi

# Phase 4: Keycloak
if [[ $PHASE_FROM -le 4 && $PHASE_TO -ge 4 ]]; then
  start_phase "Phase 4: Keycloak"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/keycloak/rbac.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/keycloak/service.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/keycloak/service-headless.yaml"
  kube_apply_subst "${REPO_ROOT}/services/keycloak/keycloak/deployment.yaml"
  wait_for_deployment keycloak keycloak 600s

  # Health check
  log_info "Verifying Keycloak health..."
  kubectl exec -n keycloak deploy/keycloak -- curl -sf http://localhost:8080/realms/master > /dev/null \
    || log_warn "Keycloak master realm not yet responding (may need a moment)"

  end_phase "Phase 4: Keycloak"
fi

# Phase 5: Gateway + HTTPRoute + HPA
if [[ $PHASE_FROM -le 5 && $PHASE_TO -ge 5 ]]; then
  start_phase "Phase 5: Gateway + HTTPRoute + HPA"
  kube_apply_subst "${REPO_ROOT}/services/keycloak/gateway.yaml"
  kube_apply_subst "${REPO_ROOT}/services/keycloak/httproute.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/keycloak/hpa.yaml"
  wait_for_tls_secret keycloak "keycloak-${DOMAIN_DASHED}-tls" 300
  end_phase "Phase 5: Gateway + HTTPRoute + HPA"
fi

# Phase 6: OAuth2-proxy
if [[ $PHASE_FROM -le 6 && $PHASE_TO -ge 6 ]]; then
  start_phase "Phase 6: OAuth2-proxy"
  log_info "Applying OAuth2-proxy instances..."
  log_warn "NOTE: Run setup-keycloak.sh BEFORE this phase to create OIDC clients"

  # External secrets for OIDC client credentials
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/external-secret-prometheus.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/external-secret-alertmanager.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/external-secret-hubble.yaml"

  # OAuth2-proxy deployments
  kube_apply_subst "${REPO_ROOT}/services/keycloak/oauth2-proxy/prometheus.yaml"
  kube_apply_subst "${REPO_ROOT}/services/keycloak/oauth2-proxy/alertmanager.yaml"
  kube_apply_subst "${REPO_ROOT}/services/keycloak/oauth2-proxy/hubble.yaml"

  # Middleware CRDs
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/middleware-prometheus.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/middleware-alertmanager.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/middleware-hubble.yaml"

  end_phase "Phase 6: OAuth2-proxy"
fi

# Phase 7: Monitoring + Verify
if [[ $PHASE_FROM -le 7 && $PHASE_TO -ge 7 ]]; then
  start_phase "Phase 7: Monitoring + Verify"
  kubectl apply -k "${REPO_ROOT}/services/keycloak/monitoring/"
  end_phase "Phase 7: Monitoring + Verify"
fi

log_ok "Keycloak deployment complete"
