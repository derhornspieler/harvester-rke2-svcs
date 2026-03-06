#!/usr/bin/env bash
# teardown-pki-secrets.sh — Tear down Bundle 1 (Vault, cert-manager, ESO)
# Reverse of deploy-pki-secrets.sh: ESO, cert-manager, Vault seal/delete, namespaces.
# WARNING: This removes the PKI foundation. All TLS certs will become unresolvable.
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
PHASE_TO=5
DRY_RUN=false
FORCE=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Tear down Bundle 1: PKI & Secrets (Vault + cert-manager + ESO).
WARNING: This removes the entire PKI and secrets foundation.

Options:
  --phase N       Run only phase N
  --from N        Start from phase N (default: 1)
  --to N          Stop after phase N (default: 5)
  --dry-run       Print what would be done without making changes
  --force         Skip dependency guards
  -h, --help      Show this help

Phases:
  1  ESO                Delete External Secrets Operator Helm release
  2  cert-manager       Delete cert-manager Helm release, ClusterIssuers, CRDs
  3  Vault seal         Seal Vault (data preserved on PVCs)
  4  Vault delete       Delete Vault Helm release and PVCs
  5  Namespaces         Delete vault, cert-manager, external-secrets namespaces
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

# Dependency guard: keycloak, minio, database, monitoring, harbor, argocd, gitlab must not exist
if [[ "$FORCE" != "true" ]]; then
  for ns in keycloak minio database monitoring harbor argocd gitlab; do
    if kubectl get namespace "$ns" &>/dev/null; then
      die "Namespace ${ns} still exists. Tear down all dependent bundles first or use --force."
    fi
  done
fi

# Phase 1: Delete External Secrets Operator
if [[ $PHASE_FROM -le 1 && $PHASE_TO -ge 1 ]]; then
  start_phase "Phase 1: External Secrets Operator"

  log_info "Deleting ESO monitoring..."
  safe_delete -k "${REPO_ROOT}/services/external-secrets/monitoring/" --ignore-not-found

  log_info "Deleting External Secrets Operator Helm release..."
  run helm uninstall external-secrets -n external-secrets --wait --timeout 5m 2>/dev/null || true

  end_phase "Phase 1: External Secrets Operator"
fi

# Phase 2: Delete cert-manager
if [[ $PHASE_FROM -le 2 && $PHASE_TO -ge 2 ]]; then
  start_phase "Phase 2: cert-manager"

  log_info "Deleting cert-manager monitoring..."
  safe_delete -k "${REPO_ROOT}/services/cert-manager/monitoring/" --ignore-not-found

  log_info "Deleting ClusterIssuer vault-issuer..."
  safe_delete clusterissuer vault-issuer --ignore-not-found

  log_info "Deleting cert-manager RBAC..."
  safe_delete -f "${REPO_ROOT}/services/cert-manager/rbac.yaml" --ignore-not-found

  log_info "Deleting cert-manager Helm release..."
  run helm uninstall cert-manager -n cert-manager --wait --timeout 5m 2>/dev/null || true

  log_info "Deleting cert-manager CRDs..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] kubectl delete crd certificates.cert-manager.io (and related CRDs)"
  else
    kubectl delete crd \
      certificates.cert-manager.io \
      certificaterequests.cert-manager.io \
      challenges.acme.cert-manager.io \
      clusterissuers.cert-manager.io \
      issuers.cert-manager.io \
      orders.acme.cert-manager.io \
      2>/dev/null || true
  fi

  end_phase "Phase 2: cert-manager"
fi

# Phase 3: Seal Vault (preserve data)
if [[ $PHASE_FROM -le 3 && $PHASE_TO -ge 3 ]]; then
  start_phase "Phase 3: Vault Seal"

  if [[ -f "$VAULT_INIT_FILE" ]]; then
    root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")

    # Delete Vault K8s auth config and cert-manager policy before sealing
    log_info "Cleaning up Vault K8s auth and cert-manager policy..."
    vault_teardown_exec "$root_token" policy delete "cert-manager-pki"
    vault_teardown_exec "$root_token" auth disable kubernetes

    log_info "Sealing Vault..."
    for i in 0 1 2; do
      if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] vault operator seal (vault-${i})"
      else
        kubectl exec -n vault "vault-${i}" -- env \
          VAULT_ADDR=http://127.0.0.1:8200 \
          VAULT_TOKEN="$root_token" \
          vault operator seal 2>/dev/null || true
      fi
    done
    log_ok "Vault sealed (data preserved on PVCs)"
  else
    log_warn "Vault init file not found — cannot seal Vault"
  fi

  end_phase "Phase 3: Vault Seal"
fi

# Phase 4: Delete Vault Helm release and PVCs
if [[ $PHASE_FROM -le 4 && $PHASE_TO -ge 4 ]]; then
  start_phase "Phase 4: Vault Helm Release + PVCs"

  log_info "Deleting Vault monitoring..."
  safe_delete -k "${REPO_ROOT}/services/vault/monitoring/" --ignore-not-found

  log_info "Deleting Vault VolumeAutoscalers..."
  safe_delete -f "${REPO_ROOT}/services/vault/volume-autoscalers.yaml" --ignore-not-found

  log_info "Deleting Vault ingress..."
  safe_delete httproute vault -n vault --ignore-not-found
  safe_delete gateway vault -n vault --ignore-not-found

  log_info "Deleting Vault Helm release..."
  run helm uninstall vault -n vault --wait --timeout 5m 2>/dev/null || true

  log_info "Deleting Vault PVCs..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] kubectl delete pvc --all -n vault"
  else
    kubectl delete pvc --all -n vault --wait=false 2>/dev/null || true
  fi

  end_phase "Phase 4: Vault Helm Release + PVCs"
fi

# Phase 5: Delete namespaces
if [[ $PHASE_FROM -le 5 && $PHASE_TO -ge 5 ]]; then
  start_phase "Phase 5: Namespaces"

  for ns in external-secrets cert-manager vault; do
    log_info "Deleting ${ns} namespace..."
    safe_delete namespace "$ns" --ignore-not-found --wait=true --timeout=120s
  done

  end_phase "Phase 5: Namespaces"
fi

log_ok "Bundle 1 (PKI & Secrets) teardown complete"
log_warn "Remember: vault-init.json still contains unseal keys and root token. Secure or delete it."
