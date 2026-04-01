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

# CLI Parsing
PHASE_FROM=1
PHASE_TO=3
VALIDATE_ONLY=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Deploy Hubble observability (Cilium HelmChartConfig + Hubble UI ingress + OAuth2-proxy).

WARNING: Phase 1 applies a HelmChartConfig to kube-system which triggers a Cilium
DaemonSet rolling restart. This restarts the CNI on every node. Plan for brief
network disruptions on each node as its Cilium agent restarts.

Options:
  --phase N       Run only phase N
  --from N        Start from phase N (default: 1)
  --to N          Stop after phase N (default: 3)
  --validate      Health check all components (no changes)
  -h, --help      Show this help

Phases:
  1  HelmChartConfig        Apply Cilium override to enable Hubble, wait for rollout
  2  Ingress + OAuth2       Gateway, HTTPRoute, ExternalSecret, OAuth2-proxy, Middleware
  3  Verify                 Check hubble-relay, hubble-ui, hubble-metrics service
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
  start_phase "Validation: Hubble Health Check"

  log_info "Checking Cilium DaemonSet..."
  if kubectl -n kube-system get daemonset cilium \
    -o jsonpath='{.status.numberReady}' 2>/dev/null; then
    echo " node(s) ready"
  else
    log_error "Cilium DaemonSet not found"
  fi

  log_info "Checking hubble-relay..."
  if kubectl -n kube-system get deployment hubble-relay \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null; then
    echo " replica(s) ready"
  else
    log_error "hubble-relay not found"
  fi

  log_info "Checking hubble-ui..."
  if kubectl -n kube-system get deployment hubble-ui \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null; then
    echo " replica(s) ready"
  else
    log_error "hubble-ui not found"
  fi

  log_info "Checking hubble-metrics service..."
  if kubectl -n kube-system get service hubble-metrics &>/dev/null; then
    log_ok "hubble-metrics service exists"
  else
    log_warn "hubble-metrics service not found"
  fi

  log_info "Checking OAuth2-proxy for Hubble..."
  if kubectl -n kube-system get deployment oauth2-proxy-hubble \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null; then
    echo " replica(s) ready"
  else
    log_warn "oauth2-proxy-hubble not found (Phase 2 may not have been run)"
  fi

  log_info "Checking TLS secret..."
  if kubectl -n kube-system get secret "hubble-${DOMAIN_DASHED}-tls" &>/dev/null; then
    log_ok "TLS secret hubble-${DOMAIN_DASHED}-tls exists"
  else
    log_warn "TLS secret hubble-${DOMAIN_DASHED}-tls not found"
  fi

  end_phase "Validation: Hubble Health Check"
  exit 0
fi

# Phase 1: HelmChartConfig — enable Hubble in Cilium
if [[ $PHASE_FROM -le 1 && $PHASE_TO -ge 1 ]]; then
  start_phase "Phase 1: HelmChartConfig (Cilium + Hubble)"

  log_warn "Applying HelmChartConfig to kube-system — this triggers a Cilium DaemonSet rolling restart."
  log_warn "All nodes will experience a brief CNI restart. Network disruptions are expected per-node."

  kubectl apply -f "${REPO_ROOT}/services/cilium/helmchartconfig.yaml"

  log_info "Waiting for Cilium DaemonSet rollout to complete..."
  kubectl -n kube-system rollout status daemonset/cilium --timeout=600s

  log_info "Waiting for hubble-relay deployment..."
  wait_for_deployment kube-system hubble-relay 300s

  log_info "Waiting for hubble-ui deployment..."
  wait_for_deployment kube-system hubble-ui 300s

  end_phase "Phase 1: HelmChartConfig (Cilium + Hubble)"
fi

# Phase 2: Hubble UI Ingress + OAuth2-proxy
if [[ $PHASE_FROM -le 2 && $PHASE_TO -ge 2 ]]; then
  start_phase "Phase 2: Ingress + OAuth2-proxy"

  # Ensure vault-root-ca ConfigMap exists in kube-system (OAuth2-proxy needs it)
  ROOT_CA_CERT="${ROOT_CA_CERT:-${REPO_ROOT}/services/pki/roots/root-ca.pem}"
  if [[ -f "$ROOT_CA_CERT" ]]; then
    log_info "Ensuring vault-root-ca ConfigMap in kube-system..."
    kubectl create configmap vault-root-ca \
      --namespace=kube-system \
      --from-file=ca.crt="$ROOT_CA_CERT" \
      --dry-run=client -o yaml | kubectl apply -f -
  else
    log_warn "Root CA cert not found at ${ROOT_CA_CERT} — OAuth2-proxy OIDC TLS may fail"
  fi

  # Ensure ESO SecretStore exists in kube-system (for ExternalSecret)
  VAULT_INIT_FILE="${VAULT_INIT_FILE:-${REPO_ROOT}/vault-init.json}"
  if [[ -f "$VAULT_INIT_FILE" ]]; then
    root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")

    log_info "Ensuring Vault policy for kube-system ESO..."
    kubectl exec -i -n vault vault-0 -- env \
      VAULT_ADDR=http://127.0.0.1:8200 \
      VAULT_TOKEN="$root_token" \
      vault policy write "eso-kube-system" - <<POLICY
path "kv/data/oidc/*" {
  capabilities = ["read"]
}
path "kv/metadata/oidc/*" {
  capabilities = ["read", "list"]
}
path "kv/data/services/kube-system/*" {
  capabilities = ["read"]
}
path "kv/metadata/services/kube-system/*" {
  capabilities = ["read", "list"]
}
POLICY

    log_info "Ensuring Vault Kubernetes auth role for kube-system..."
    kubectl exec -i -n vault vault-0 -- env \
      VAULT_ADDR=http://127.0.0.1:8200 \
      VAULT_TOKEN="$root_token" \
      vault write auth/kubernetes/role/eso-kube-system \
        bound_service_account_names=eso-secrets \
        bound_service_account_namespaces=kube-system \
        policies=eso-kube-system \
        ttl=1h

    kubectl create serviceaccount eso-secrets -n kube-system \
      --dry-run=client -o yaml | kubectl apply -f -

    kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: kube-system
spec:
  provider:
    vault:
      server: http://vault.vault.svc.cluster.local:8200
      path: kv
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: eso-kube-system
          serviceAccountRef:
            name: eso-secrets
EOF
  else
    log_warn "Vault init file not found — skipping SecretStore creation (ExternalSecret may fail)"
  fi

  # Apply ExternalSecret (syncs OAuth2-proxy secrets from Vault)
  log_info "Applying ExternalSecret for OAuth2-proxy Hubble..."
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/external-secret-hubble.yaml"

  # Apply OAuth2-proxy Deployment + Service (contains CHANGEME tokens)
  log_info "Applying OAuth2-proxy Deployment + Service..."
  kube_apply_subst "${REPO_ROOT}/services/keycloak/oauth2-proxy/hubble.yaml"

  # Apply Middleware (no CHANGEME tokens — plain apply)
  log_info "Applying Traefik Middleware for Hubble..."
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/middleware-hubble.yaml"

  # Apply Gateway and HTTPRoute (contain CHANGEME tokens)
  log_info "Applying Hubble Gateway..."
  kube_apply_subst "${REPO_ROOT}/services/hubble/gateway.yaml"

  log_info "Applying Hubble HTTPRoute..."
  kube_apply_subst "${REPO_ROOT}/services/hubble/httproute.yaml"

  end_phase "Phase 2: Ingress + OAuth2-proxy"
fi

# Phase 3: Verify
if [[ $PHASE_FROM -le 3 && $PHASE_TO -ge 3 ]]; then
  start_phase "Phase 3: Verify"

  wait_for_pods_ready kube-system "k8s-app=hubble-relay" 300
  wait_for_pods_ready kube-system "k8s-app=hubble-ui" 300
  wait_for_deployment kube-system oauth2-proxy-hubble 300s
  wait_for_tls_secret kube-system "hubble-${DOMAIN_DASHED}-tls" 300

  # Verify hubble-metrics service exists (needed for ServiceMonitor scraping)
  if kubectl -n kube-system get service hubble-metrics &>/dev/null; then
    log_ok "hubble-metrics service exists — ServiceMonitor will scrape it"
  else
    log_warn "hubble-metrics service not found — Prometheus scraping will fail"
  fi

  # Verify ExternalSecret is synced
  es_status=$(kubectl -n kube-system get externalsecret oauth2-proxy-hubble \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [[ "$es_status" == "True" ]]; then
    log_ok "ExternalSecret oauth2-proxy-hubble is synced"
  else
    log_warn "ExternalSecret oauth2-proxy-hubble status: ${es_status} (may need Vault OIDC secrets seeded)"
  fi

  end_phase "Phase 3: Verify"
fi

log_ok "Hubble deployment complete"
