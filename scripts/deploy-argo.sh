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

# Vault init file
VAULT_INIT_FILE="${VAULT_INIT_FILE:-${REPO_ROOT}/vault-init.json}"

# Helm chart sources (OCI registries)
HELM_CHART_ARGOCD="${HELM_CHART_ARGOCD:-oci://ghcr.io/argoproj/argo-helm/argo-cd}"
HELM_CHART_ROLLOUTS="${HELM_CHART_ROLLOUTS:-oci://ghcr.io/argoproj/argo-helm/argo-rollouts}"
HELM_CHART_WORKFLOWS="${HELM_CHART_WORKFLOWS:-oci://ghcr.io/argoproj/argo-helm/argo-workflows}"

# Basic-auth passwords (auto-generate if not set)
ARGO_BASIC_AUTH_PASS="${ARGO_BASIC_AUTH_PASS:-$(openssl rand -base64 24)}"
WORKFLOWS_BASIC_AUTH_PASS="${WORKFLOWS_BASIC_AUTH_PASS:-$(openssl rand -base64 24)}"
export ARGO_BASIC_AUTH_PASS WORKFLOWS_BASIC_AUTH_PASS

# CLI Parsing
PHASE_FROM=1
PHASE_TO=7
VALIDATE_ONLY=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Deploy Argo GitOps platform: ArgoCD, Argo Rollouts, and Argo Workflows.

Options:
  --phase N       Run only phase N
  --from N        Start from phase N (default: 1)
  --to N          Stop after phase N (default: 7)
  --validate      Health check all components (no changes)
  -h, --help      Show this help

Phases:
  1  Namespaces           Create argocd, argo-rollouts, argo-workflows namespaces
  2  ESO SecretStores     Vault K8s auth roles + SecretStores per namespace
  3  ArgoCD Helm          Helm install ArgoCD
  4  Argo Rollouts Helm   Helm install Argo Rollouts
  5  Argo Workflows Helm  Helm install Argo Workflows
  6  Gateways + Auth      Gateways, HTTPRoutes, basic-auth, AnalysisTemplates
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

# Temp files for Helm values — single trap cleans all on exit
_argocd_values=""
_rollouts_values=""
_workflows_values=""
trap 'rm -f "$_argocd_values" "$_rollouts_values" "$_workflows_values"' EXIT

# Validation mode
if [[ "$VALIDATE_ONLY" == "true" ]]; then
  start_phase "Validation: Argo Platform Health Check"

  log_info "Checking argocd-server deployment..."
  if kubectl -n argocd get deployment argocd-server \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null; then
    echo " replica(s) ready"
  else
    log_error "argocd-server not found"
  fi

  log_info "Checking argo-rollouts deployment..."
  if kubectl -n argo-rollouts get deployment argo-rollouts \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null; then
    echo " replica(s) ready"
  else
    log_error "argo-rollouts not found"
  fi

  log_info "Checking argo-workflows deployment..."
  if kubectl -n argo-workflows get deployment argo-workflows-server \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null; then
    echo " replica(s) ready"
  else
    log_error "argo-workflows-server not found"
  fi

  log_info "Checking TLS secrets..."
  for pair in "argocd:argo-${DOMAIN_DASHED}-tls" \
              "argo-rollouts:rollouts-${DOMAIN_DASHED}-tls" \
              "argo-workflows:workflows-${DOMAIN_DASHED}-tls"; do
    local_ns="${pair%%:*}"
    local_secret="${pair##*:}"
    if kubectl -n "$local_ns" get secret "$local_secret" &>/dev/null; then
      log_ok "TLS secret ${local_secret} exists in ${local_ns}"
    else
      log_warn "TLS secret ${local_secret} not found in ${local_ns}"
    fi
  done

  end_phase "Validation: Argo Platform Health Check"
  exit 0
fi

# Phase 1: Namespaces
if [[ $PHASE_FROM -le 1 && $PHASE_TO -ge 1 ]]; then
  start_phase "Phase 1: Namespaces"
  kubectl apply -f "${REPO_ROOT}/services/argo/argocd/namespace.yaml"
  kubectl apply -f "${REPO_ROOT}/services/argo/argo-rollouts/namespace.yaml"
  kubectl apply -f "${REPO_ROOT}/services/argo/argo-workflows/namespace.yaml"
  end_phase "Phase 1: Namespaces"
fi

# Phase 2: ESO SecretStores
if [[ $PHASE_FROM -le 2 && $PHASE_TO -ge 2 ]]; then
  start_phase "Phase 2: ESO SecretStores"
  [[ -f "$VAULT_INIT_FILE" ]] || die "Vault init file not found: ${VAULT_INIT_FILE}"
  root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")

  # Create Vault K8s auth roles and policies for each Argo namespace
  for ns in argocd argo-rollouts argo-workflows; do
    log_info "Creating Vault K8s auth role eso-${ns}..."
    vault_exec "$root_token" write "auth/kubernetes/role/eso-${ns}" \
      bound_service_account_names=eso-secrets \
      "bound_service_account_namespaces=${ns}" \
      "policies=eso-${ns}" \
      ttl=1h

    # Write policy via kubectl exec with stdin (vault_exec doesn't support stdin)
    kubectl exec -i -n vault vault-0 -- env \
      VAULT_ADDR=http://127.0.0.1:8200 \
      VAULT_TOKEN="$root_token" \
      vault policy write "eso-${ns}" - <<POLICY
path "kv/data/services/${ns}/*" {
  capabilities = ["read"]
}
path "kv/metadata/services/${ns}/*" {
  capabilities = ["read", "list"]
}
POLICY

    # Create service account and SecretStore in each namespace
    kubectl create serviceaccount eso-secrets -n "$ns" \
      --dry-run=client -o yaml | kubectl apply -f -

    kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: ${ns}
spec:
  provider:
    vault:
      server: http://vault.vault.svc.cluster.local:8200
      path: kv
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: eso-${ns}
          serviceAccountRef:
            name: eso-secrets
EOF
  done

  end_phase "Phase 2: ESO SecretStores"
fi

# Phase 3: ArgoCD Helm Install
if [[ $PHASE_FROM -le 3 && $PHASE_TO -ge 3 ]]; then
  start_phase "Phase 3: ArgoCD Helm Install"
  _argocd_values=$(mktemp /tmp/argocd-values.XXXXXX.yaml)
  _subst_changeme < "${REPO_ROOT}/services/argo/argocd/argocd-values.yaml" > "$_argocd_values"
  chmod 600 "$_argocd_values"
  helm_install_if_needed argocd "$HELM_CHART_ARGOCD" argocd \
    --version 7.8.8 \
    -f "$_argocd_values" \
    --wait --timeout 10m
  rm -f "$_argocd_values"
  wait_for_deployment argocd argocd-server 300s
  end_phase "Phase 3: ArgoCD Helm Install"
fi

# Phase 4: Argo Rollouts Helm Install
if [[ $PHASE_FROM -le 4 && $PHASE_TO -ge 4 ]]; then
  start_phase "Phase 4: Argo Rollouts Helm Install"
  _rollouts_values=$(mktemp /tmp/rollouts-values.XXXXXX.yaml)
  _subst_changeme < "${REPO_ROOT}/services/argo/argo-rollouts/argo-rollouts-values.yaml" > "$_rollouts_values"
  chmod 600 "$_rollouts_values"
  helm_install_if_needed argo-rollouts "$HELM_CHART_ROLLOUTS" argo-rollouts \
    --version 2.39.1 \
    -f "$_rollouts_values" \
    --wait --timeout 5m
  rm -f "$_rollouts_values"
  wait_for_deployment argo-rollouts argo-rollouts 300s
  end_phase "Phase 4: Argo Rollouts Helm Install"
fi

# Phase 5: Argo Workflows Helm Install
if [[ $PHASE_FROM -le 5 && $PHASE_TO -ge 5 ]]; then
  start_phase "Phase 5: Argo Workflows Helm Install"
  _workflows_values=$(mktemp /tmp/workflows-values.XXXXXX.yaml)
  _subst_changeme < "${REPO_ROOT}/services/argo/argo-workflows/argo-workflows-values.yaml" > "$_workflows_values"
  chmod 600 "$_workflows_values"
  helm_install_if_needed argo-workflows "$HELM_CHART_WORKFLOWS" argo-workflows \
    --version 0.45.1 \
    -f "$_workflows_values" \
    --wait --timeout 5m
  rm -f "$_workflows_values"
  end_phase "Phase 5: Argo Workflows Helm Install"
fi

# Phase 6: Gateways + Auth + AnalysisTemplates
if [[ $PHASE_FROM -le 6 && $PHASE_TO -ge 6 ]]; then
  start_phase "Phase 6: Gateways + Auth + AnalysisTemplates"

  # ArgoCD gateway (native OIDC, no basic-auth)
  kube_apply_subst "${REPO_ROOT}/services/argo/argocd/gateway.yaml"
  kube_apply_subst "${REPO_ROOT}/services/argo/argocd/httproute.yaml"

  # Rollouts basic-auth
  create_basic_auth_secret argo-rollouts basic-auth-rollouts admin "$ARGO_BASIC_AUTH_PASS"
  kube_apply_subst "${REPO_ROOT}/services/argo/argo-rollouts/gateway.yaml"
  kube_apply_subst "${REPO_ROOT}/services/argo/argo-rollouts/httproute.yaml"
  kubectl apply -f "${REPO_ROOT}/services/argo/argo-rollouts/middleware-basic-auth.yaml"

  # Workflows basic-auth
  create_basic_auth_secret argo-workflows basic-auth-workflows admin "$WORKFLOWS_BASIC_AUTH_PASS"
  kube_apply_subst "${REPO_ROOT}/services/argo/argo-workflows/gateway.yaml"
  kube_apply_subst "${REPO_ROOT}/services/argo/argo-workflows/httproute.yaml"
  kubectl apply -f "${REPO_ROOT}/services/argo/argo-workflows/middleware-basic-auth.yaml"

  # AnalysisTemplates
  kubectl apply -f "${REPO_ROOT}/services/argo/analysis-templates/"

  # Wait for TLS certs
  wait_for_tls_secret argocd "argo-${DOMAIN_DASHED}-tls" 300
  wait_for_tls_secret argo-rollouts "rollouts-${DOMAIN_DASHED}-tls" 300
  wait_for_tls_secret argo-workflows "workflows-${DOMAIN_DASHED}-tls" 300

  end_phase "Phase 6: Gateways + Auth + AnalysisTemplates"
fi

# Phase 7: Monitoring + Verify
if [[ $PHASE_FROM -le 7 && $PHASE_TO -ge 7 ]]; then
  start_phase "Phase 7: Monitoring + Verify"
  kubectl apply -k "${REPO_ROOT}/services/argo/monitoring/"
  # NetworkPolicies
  log_info "Applying NetworkPolicies for Argo services..."
  kubectl apply -f "${REPO_ROOT}/services/argo/argocd/networkpolicy.yaml"
  kubectl apply -f "${REPO_ROOT}/services/argo/argo-rollouts/networkpolicy.yaml"
  kubectl apply -f "${REPO_ROOT}/services/argo/argo-workflows/networkpolicy.yaml"
  end_phase "Phase 7: Monitoring + Verify"
fi

log_ok "Argo GitOps platform deployment complete"
