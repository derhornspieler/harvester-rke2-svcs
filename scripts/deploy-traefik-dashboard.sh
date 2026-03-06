#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source utility modules
source "${SCRIPT_DIR}/utils/log.sh"
source "${SCRIPT_DIR}/utils/wait.sh"
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

DASHBOARD_DIR="${REPO_ROOT}/services/traefik-dashboard"

# CLI Parsing
PHASE_FROM=1
PHASE_TO=3
VALIDATE_ONLY=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Deploy Traefik dashboard with OAuth2-proxy authentication.

Options:
  --phase N       Run only phase N
  --from N        Start from phase N (default: 1)
  --to N          Stop after phase N (default: 3)
  --validate      Health check all components (no changes)
  -h, --help      Show this help

Phases:
  1  Traefik Config      Apply HelmChartConfig (enables dashboard + custom args)
  2  OAuth2-proxy        ExternalSecret, OAuth2-proxy Deployment+Service, Middleware
  3  Ingress + Verify    Gateway, HTTPRoute, Dashboard Service, TLS verification
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
  start_phase "Validation: Traefik Dashboard Health Check"

  log_info "Checking traefik-dashboard service..."
  if kubectl -n kube-system get service traefik-dashboard &>/dev/null; then
    log_ok "traefik-dashboard service exists"
  else
    log_error "traefik-dashboard service not found"
  fi

  log_info "Checking oauth2-proxy-traefik deployment..."
  if kubectl -n kube-system get deployment oauth2-proxy-traefik \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null; then
    echo " replica(s) ready"
  else
    log_error "oauth2-proxy-traefik not found"
  fi

  log_info "Checking TLS secret..."
  if kubectl -n kube-system get secret "traefik-${DOMAIN_DASHED}-tls" &>/dev/null; then
    log_ok "TLS secret traefik-${DOMAIN_DASHED}-tls exists"
  else
    log_warn "TLS secret traefik-${DOMAIN_DASHED}-tls not found"
  fi

  end_phase "Validation: Traefik Dashboard Health Check"
  exit 0
fi

# Phase 1: HelmChartConfig (Traefik system overrides)
if [[ $PHASE_FROM -le 1 && $PHASE_TO -ge 1 ]]; then
  start_phase "Phase 1: Traefik HelmChartConfig"
  kubectl apply -f "${DASHBOARD_DIR}/helmchartconfig.yaml"
  log_info "HelmChartConfig applied — Traefik will reconcile (may take 30-60s)"
  end_phase "Phase 1: Traefik HelmChartConfig"
fi

# Phase 2: OAuth2-proxy (ExternalSecret + Deployment + Middleware)
if [[ $PHASE_FROM -le 2 && $PHASE_TO -ge 2 ]]; then
  start_phase "Phase 2: OAuth2-proxy"
  kubectl apply -f "${DASHBOARD_DIR}/external-secret.yaml"
  kube_apply_subst "${DASHBOARD_DIR}/oauth2-proxy.yaml"
  kubectl apply -f "${DASHBOARD_DIR}/middleware.yaml"
  wait_for_deployment kube-system oauth2-proxy-traefik 300s
  end_phase "Phase 2: OAuth2-proxy"
fi

# Phase 3: Ingress + Dashboard Service
if [[ $PHASE_FROM -le 3 && $PHASE_TO -ge 3 ]]; then
  start_phase "Phase 3: Ingress + Dashboard Service"
  kubectl apply -f "${DASHBOARD_DIR}/dashboard-service.yaml"
  kube_apply_subst "${DASHBOARD_DIR}/gateway.yaml"
  kube_apply_subst "${DASHBOARD_DIR}/httproute.yaml"
  wait_for_tls_secret kube-system "traefik-${DOMAIN_DASHED}-tls" 300
  end_phase "Phase 3: Ingress + Dashboard Service"
fi

log_ok "Traefik dashboard deployment complete"
