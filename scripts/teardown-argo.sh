#!/usr/bin/env bash
# teardown-argo.sh — Tear down Bundle 5 (ArgoCD + Rollouts + Workflows)
# Reverse of deploy-argo.sh: Helm releases, OAuth2-proxy, ESO, Vault, namespaces.
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
PHASE_TO=4
DRY_RUN=false
FORCE=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Tear down Bundle 5: ArgoCD + Argo Rollouts + Argo Workflows.

Options:
  --phase N       Run only phase N
  --from N        Start from phase N (default: 1)
  --to N          Stop after phase N (default: 4)
  --dry-run       Print what would be done without making changes
  --force         Skip dependency guards
  -h, --help      Show this help

Phases:
  1  Helm releases      Delete ArgoCD, Rollouts, Workflows Helm releases + monitoring
  2  Ingress + Auth     Delete Gateways, HTTPRoutes, OAuth2-proxy, Middlewares, AnalysisTemplates
  3  ESO + Vault        Delete ExternalSecrets, Vault secrets, policies, auth roles, SecretStores
  4  Namespaces         Delete argocd, argo-rollouts, argo-workflows namespaces
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

# Dry-run wrapper
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

# Dependency guard: gitlab namespace must not exist
if [[ "$FORCE" != "true" ]]; then
  if kubectl get namespace gitlab &>/dev/null; then
    die "Bundle 6 (GitLab) is still deployed. Tear it down first or use --force."
  fi
fi

# Phase 1: Delete Helm releases + monitoring + PDBs + VolumeAutoscalers
if [[ $PHASE_FROM -le 1 && $PHASE_TO -ge 1 ]]; then
  start_phase "Phase 1: Helm Releases + Monitoring"

  log_info "Deleting monitoring resources..."
  safe_delete -k "${REPO_ROOT}/services/argo/monitoring/" --ignore-not-found

  log_info "Deleting VolumeAutoscalers..."
  safe_delete -f "${REPO_ROOT}/services/argo/volume-autoscalers.yaml" --ignore-not-found

  log_info "Deleting PDBs..."
  safe_delete -f "${REPO_ROOT}/services/argo/argocd/pdbs.yaml" --ignore-not-found
  safe_delete -f "${REPO_ROOT}/services/argo/argo-rollouts/pdb.yaml" --ignore-not-found

  log_info "Deleting Argo Workflows Helm release..."
  run helm uninstall argo-workflows -n argo-workflows --wait 2>/dev/null || true

  log_info "Deleting Argo Rollouts Helm release..."
  run helm uninstall argo-rollouts -n argo-rollouts --wait 2>/dev/null || true

  log_info "Deleting ArgoCD Helm release..."
  run helm uninstall argocd -n argocd --wait --timeout 5m 2>/dev/null || true

  end_phase "Phase 1: Helm Releases + Monitoring"
fi

# Phase 2: Delete Gateways, HTTPRoutes, OAuth2-proxy, Middlewares, AnalysisTemplates
if [[ $PHASE_FROM -le 2 && $PHASE_TO -ge 2 ]]; then
  start_phase "Phase 2: Ingress + Auth + AnalysisTemplates"

  log_info "Deleting AnalysisTemplates..."
  safe_delete -f "${REPO_ROOT}/services/argo/analysis-templates/" --ignore-not-found

  log_info "Deleting Argo Workflows ingress + auth..."
  safe_delete middleware oauth2-proxy-workflows -n argo-workflows --ignore-not-found
  safe_delete httproute argo-workflows -n argo-workflows --ignore-not-found
  safe_delete gateway argo-workflows -n argo-workflows --ignore-not-found

  log_info "Deleting Argo Rollouts ingress + auth..."
  safe_delete middleware oauth2-proxy-rollouts -n argo-rollouts --ignore-not-found
  safe_delete httproute argo-rollouts -n argo-rollouts --ignore-not-found
  safe_delete gateway argo-rollouts -n argo-rollouts --ignore-not-found

  log_info "Deleting ArgoCD ingress..."
  safe_delete httproute argocd -n argocd --ignore-not-found
  safe_delete gateway argocd -n argocd --ignore-not-found

  end_phase "Phase 2: Ingress + Auth + AnalysisTemplates"
fi

# Phase 3: Delete ExternalSecrets, Vault secrets/policies/auth roles, SecretStores
if [[ $PHASE_FROM -le 3 && $PHASE_TO -ge 3 ]]; then
  start_phase "Phase 3: ESO + Vault Cleanup"

  log_info "Deleting ExternalSecrets..."
  safe_delete externalsecret oauth2-proxy-workflows -n argo-workflows --ignore-not-found
  safe_delete externalsecret oauth2-proxy-rollouts -n argo-rollouts --ignore-not-found

  if [[ -f "$VAULT_INIT_FILE" ]]; then
    root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")

    log_info "Deleting Vault KV secrets for Argo..."
    for path in kv/services/argocd kv/oidc/argocd \
      kv/oidc/rollouts-oidc kv/oidc/workflows-oidc; do
      vault_teardown_exec "$root_token" kv metadata delete "$path"
    done

    for ns in argocd argo-rollouts argo-workflows; do
      log_info "Deleting Vault policy eso-${ns}..."
      vault_teardown_exec "$root_token" policy delete "eso-${ns}"
      log_info "Deleting Vault K8s auth role eso-${ns}..."
      vault_teardown_exec "$root_token" delete "auth/kubernetes/role/eso-${ns}"
    done
  else
    log_warn "Vault init file not found — skipping Vault cleanup"
  fi

  log_info "Deleting SecretStores..."
  for ns in argocd argo-rollouts argo-workflows; do
    safe_delete secretstore vault-backend -n "$ns" --ignore-not-found
  done

  log_info "Deleting PVCs..."
  if [[ "$DRY_RUN" == "true" ]]; then
    for ns in argocd argo-rollouts argo-workflows; do
      log_info "[DRY-RUN] kubectl delete pvc --all -n ${ns}"
    done
  else
    for ns in argocd argo-rollouts argo-workflows; do
      kubectl delete pvc --all -n "$ns" --wait=false 2>/dev/null || true
    done
  fi

  end_phase "Phase 3: ESO + Vault Cleanup"
fi

# Phase 4: Delete namespaces
if [[ $PHASE_FROM -le 4 && $PHASE_TO -ge 4 ]]; then
  start_phase "Phase 4: Namespaces"

  for ns in argo-workflows argo-rollouts argocd; do
    log_info "Deleting ${ns} namespace..."
    safe_delete namespace "$ns" --ignore-not-found --wait=true --timeout=120s
  done

  end_phase "Phase 4: Namespaces"
fi

log_ok "Bundle 5 (Argo) teardown complete"
