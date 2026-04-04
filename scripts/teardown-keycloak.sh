#!/usr/bin/env bash
# teardown-keycloak.sh — Tear down Bundle 2 (Keycloak, CNPG operator, MinIO)
# Reverse of deploy-keycloak.sh + setup-keycloak.sh: Keycloak, CNPG cluster,
# CNPG operator, MinIO, Vault, namespaces.
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

Tear down Bundle 2: Keycloak + CNPG operator + MinIO.

Options:
  --phase N       Run only phase N
  --from N        Start from phase N (default: 1)
  --to N          Stop after phase N (default: 6)
  --dry-run       Print what would be done without making changes
  --force         Skip dependency guards
  -h, --help      Show this help

Phases:
  1  Keycloak           Delete Keycloak deployment, services, ingress, monitoring
  2  CNPG cluster       Delete keycloak-pg CNPG cluster, CNPG operator Helm release
  3  MinIO              Delete MinIO deployment, services, PVCs
  4  Vault              Delete Vault secrets, policies, auth roles
  5  SecretStores + ESO Delete SecretStores, ExternalSecrets, service accounts
  6  Namespaces         Delete keycloak, minio, database namespaces
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

# Dependency guard: monitoring, harbor, argocd, gitlab namespaces must not exist
if [[ "$FORCE" != "true" ]]; then
  for ns in monitoring harbor argocd gitlab; do
    if kubectl get namespace "$ns" &>/dev/null; then
      die "Namespace ${ns} still exists. Tear down dependent bundles first or use --force."
    fi
  done
fi

# Phase 1: Delete Keycloak deployment, services, ingress, OAuth2-proxy, monitoring
if [[ $PHASE_FROM -le 1 && $PHASE_TO -ge 1 ]]; then
  start_phase "Phase 1: Keycloak"

  log_info "Deleting Keycloak monitoring..."
  safe_delete -k "${REPO_ROOT}/services/keycloak/monitoring/" --ignore-not-found

  log_info "Deleting OAuth2-proxy instances (monitoring + kube-system)..."
  # Prometheus OAuth2-proxy
  safe_delete deployment oauth2-proxy-prometheus -n monitoring --ignore-not-found
  safe_delete service oauth2-proxy-prometheus -n monitoring --ignore-not-found
  safe_delete middleware oauth2-proxy-prometheus -n monitoring --ignore-not-found
  safe_delete externalsecret oauth2-proxy-prometheus -n monitoring --ignore-not-found
  # Alertmanager OAuth2-proxy
  safe_delete deployment oauth2-proxy-alertmanager -n monitoring --ignore-not-found
  safe_delete service oauth2-proxy-alertmanager -n monitoring --ignore-not-found
  safe_delete middleware oauth2-proxy-alertmanager -n monitoring --ignore-not-found
  safe_delete externalsecret oauth2-proxy-alertmanager -n monitoring --ignore-not-found
  # Hubble OAuth2-proxy
  safe_delete deployment oauth2-proxy-hubble -n kube-system --ignore-not-found
  safe_delete service oauth2-proxy-hubble -n kube-system --ignore-not-found
  safe_delete middleware oauth2-proxy-hubble -n kube-system --ignore-not-found
  safe_delete externalsecret oauth2-proxy-hubble -n kube-system --ignore-not-found
  # Grafana OIDC ExternalSecret
  safe_delete externalsecret grafana-oidc-secret -n monitoring --ignore-not-found

  log_info "Deleting Keycloak HPA..."
  safe_delete -f "${REPO_ROOT}/services/keycloak/keycloak/hpa.yaml" --ignore-not-found

  log_info "Deleting Keycloak ingress..."
  safe_delete httproute keycloak -n keycloak --ignore-not-found
  safe_delete gateway keycloak -n keycloak --ignore-not-found

  log_info "Deleting Keycloak deployment and services..."
  safe_delete deployment keycloak -n keycloak --ignore-not-found
  safe_delete service keycloak -n keycloak --ignore-not-found
  safe_delete service keycloak-headless -n keycloak --ignore-not-found
  safe_delete -f "${REPO_ROOT}/services/keycloak/keycloak/rbac.yaml" --ignore-not-found

  end_phase "Phase 1: Keycloak"
fi

# Phase 2: Delete CNPG keycloak-pg cluster, CNPG operator
if [[ $PHASE_FROM -le 2 && $PHASE_TO -ge 2 ]]; then
  start_phase "Phase 2: CNPG Cluster + Operator"

  log_info "Deleting Keycloak VolumeAutoscalers..."
  safe_delete -f "${REPO_ROOT}/services/keycloak/volume-autoscalers.yaml" --ignore-not-found

  log_info "Deleting CNPG scheduled backup..."
  safe_delete -f "${REPO_ROOT}/services/keycloak/postgres/keycloak-pg-scheduled-backup.yaml" --ignore-not-found

  log_info "Deleting CNPG keycloak-pg cluster..."
  safe_delete clusters.postgresql.cnpg.io keycloak-pg -n database --ignore-not-found

  log_info "Deleting CNPG operator HPA and PDB..."
  safe_delete -f "${REPO_ROOT}/services/cnpg-operator/hpa.yaml" --ignore-not-found
  safe_delete -f "${REPO_ROOT}/services/cnpg-operator/pdb.yaml" --ignore-not-found

  log_info "Deleting CNPG operator Helm release..."
  run helm uninstall cnpg -n cnpg-system --wait --timeout 5m 2>/dev/null || true

  log_info "Deleting stale CNPG webhook configurations..."
  safe_delete validatingwebhookconfiguration cnpg-validating-webhook-configuration --ignore-not-found
  safe_delete mutatingwebhookconfiguration cnpg-mutating-webhook-configuration --ignore-not-found

  log_info "Deleting CNPG CRDs (orphaned CRDs block Helm reinstall)..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] kubectl delete crd --selector=app.kubernetes.io/name=cloudnative-pg"
  else
    kubectl get crd -o name 2>/dev/null | grep cnpg | xargs -r kubectl delete 2>/dev/null || true
  fi

  log_info "Deleting cnpg-system namespace..."
  safe_delete namespace cnpg-system --ignore-not-found --wait=true --timeout=120s

  end_phase "Phase 2: CNPG Cluster + Operator"
fi

# Phase 3: Delete MinIO
if [[ $PHASE_FROM -le 3 && $PHASE_TO -ge 3 ]]; then
  start_phase "Phase 3: MinIO"

  log_info "Deleting MinIO deployment and service..."
  safe_delete -f "${REPO_ROOT}/services/harbor/minio/service.yaml" --ignore-not-found
  safe_delete -f "${REPO_ROOT}/services/harbor/minio/deployment.yaml" --ignore-not-found

  log_info "Deleting MinIO PVCs..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] kubectl delete pvc --all -n minio"
  else
    kubectl delete pvc --all -n minio --wait=false 2>/dev/null || true
  fi

  end_phase "Phase 3: MinIO"
fi

# Phase 4: Delete Vault secrets, policies, auth roles
if [[ $PHASE_FROM -le 4 && $PHASE_TO -ge 4 ]]; then
  start_phase "Phase 4: Vault Cleanup"

  if [[ -f "$VAULT_INIT_FILE" ]]; then
    root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")

    log_info "Deleting Vault KV secrets for Keycloak..."
    for path in kv/services/keycloak/admin-secret kv/services/keycloak/postgres-secret \
      kv/services/database/keycloak-pg kv/services/minio/root-credentials; do
      vault_teardown_exec "$root_token" kv metadata delete "$path"
    done

    log_info "Deleting all OIDC Vault secrets (created by setup-keycloak.sh)..."
    for client_id in grafana prometheus-oidc alertmanager-oidc hubble-oidc \
      traefik-oidc rollouts-oidc workflows-oidc argocd harbor gitlab; do
      vault_teardown_exec "$root_token" kv metadata delete "kv/oidc/${client_id}"
    done

    for ns in minio keycloak database; do
      log_info "Deleting Vault policy eso-${ns}..."
      vault_teardown_exec "$root_token" policy delete "eso-${ns}"
      log_info "Deleting Vault K8s auth role eso-${ns}..."
      vault_teardown_exec "$root_token" delete "auth/kubernetes/role/eso-${ns}"
    done
  else
    log_warn "Vault init file not found — skipping Vault cleanup"
  fi

  end_phase "Phase 4: Vault Cleanup"
fi

# Phase 5: Delete SecretStores, ExternalSecrets, service accounts
if [[ $PHASE_FROM -le 5 && $PHASE_TO -ge 5 ]]; then
  start_phase "Phase 5: SecretStores + ExternalSecrets"

  log_info "Deleting ExternalSecrets in keycloak namespace..."
  safe_delete externalsecret keycloak-admin-secret -n keycloak --ignore-not-found
  safe_delete externalsecret keycloak-postgres-secret -n keycloak --ignore-not-found

  log_info "Deleting ExternalSecrets in database namespace..."
  safe_delete externalsecret keycloak-pg-credentials -n database --ignore-not-found

  log_info "Deleting ExternalSecrets in minio namespace..."
  safe_delete externalsecret minio-root-credentials -n minio --ignore-not-found

  log_info "Deleting SecretStores..."
  for ns in minio keycloak database; do
    safe_delete secretstore vault-backend -n "$ns" --ignore-not-found
  done

  end_phase "Phase 5: SecretStores + ExternalSecrets"
fi

# Phase 6: Delete namespaces
if [[ $PHASE_FROM -le 6 && $PHASE_TO -ge 6 ]]; then
  start_phase "Phase 6: Namespaces"

  log_info "Deleting keycloak namespace..."
  safe_delete namespace keycloak --ignore-not-found --wait=true --timeout=120s
  log_info "Deleting minio namespace..."
  safe_delete namespace minio --ignore-not-found --wait=true --timeout=120s
  log_info "Deleting database namespace..."
  safe_delete namespace database --ignore-not-found --wait=true --timeout=120s

  end_phase "Phase 6: Namespaces"
fi

log_ok "Bundle 2 (Keycloak) teardown complete"
