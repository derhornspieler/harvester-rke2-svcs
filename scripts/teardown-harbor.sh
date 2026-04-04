#!/usr/bin/env bash
# teardown-harbor.sh — Tear down Bundle 4 (Harbor)
# Reverse of deploy-harbor.sh: Helm release, CNPG, Valkey, ESO, Vault, namespace.
# MinIO buckets are preserved — only Harbor-specific access keys/policies are removed.
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

Tear down Bundle 4: Harbor container registry.

Options:
  --phase N       Run only phase N
  --from N        Start from phase N (default: 1)
  --to N          Stop after phase N (default: 4)
  --dry-run       Print what would be done without making changes
  --force         Skip dependency guards
  -h, --help      Show this help

Phases:
  1  Harbor Helm       Delete Harbor Helm release, ingress, HPAs, PDBs, monitoring
  2  Data plane        Delete CNPG harbor-pg, Valkey CRs, ExternalSecrets
  3  Vault + ESO       Delete Vault secrets, policies, auth roles, SecretStores
  4  PVCs + Namespace  Delete PVCs, harbor namespace
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

# Dependency guard: gitlab namespace must not exist (GitLab pushes to Harbor)
if [[ "$FORCE" != "true" ]]; then
  if kubectl get namespace gitlab &>/dev/null; then
    die "Bundle 6 (GitLab) is still deployed. Tear it down first or use --force."
  fi
fi

# Phase 1: Delete Harbor Helm release, ingress, HPAs, PDBs, monitoring
if [[ $PHASE_FROM -le 1 && $PHASE_TO -ge 1 ]]; then
  start_phase "Phase 1: Harbor Helm Release + Ingress + Monitoring"

  log_info "Deleting monitoring resources..."
  safe_delete -k "${REPO_ROOT}/services/harbor/monitoring/" --ignore-not-found

  log_info "Deleting VolumeAutoscalers..."
  safe_delete -f "${REPO_ROOT}/services/harbor/volume-autoscalers.yaml" --ignore-not-found

  log_info "Deleting PDBs..."
  safe_delete -f "${REPO_ROOT}/services/harbor/pdbs.yaml" --ignore-not-found

  log_info "Deleting HPAs..."
  safe_delete -f "${REPO_ROOT}/services/harbor/hpa-core.yaml" --ignore-not-found
  safe_delete -f "${REPO_ROOT}/services/harbor/hpa-registry.yaml" --ignore-not-found
  safe_delete -f "${REPO_ROOT}/services/harbor/hpa-trivy.yaml" --ignore-not-found

  log_info "Deleting Harbor ingress..."
  safe_delete httproute harbor -n harbor --ignore-not-found
  safe_delete gateway harbor -n harbor --ignore-not-found

  log_info "Deleting Harbor Helm release..."
  run helm uninstall harbor -n harbor --wait --timeout 5m 2>/dev/null || true

  end_phase "Phase 1: Harbor Helm Release + Ingress + Monitoring"
fi

# Phase 2: Delete CNPG harbor-pg, Valkey Redis CRs, ExternalSecrets
if [[ $PHASE_FROM -le 2 && $PHASE_TO -ge 2 ]]; then
  start_phase "Phase 2: Data Plane (CNPG, Valkey, ExternalSecrets)"

  log_info "Deleting Valkey Sentinel and Replication CRs..."
  safe_delete redissentinel harbor-redis -n harbor --ignore-not-found
  safe_delete redisreplication harbor-redis -n harbor --ignore-not-found

  log_info "Deleting CNPG scheduled backup..."
  safe_delete -f "${REPO_ROOT}/services/harbor/postgres/harbor-pg-scheduled-backup.yaml" --ignore-not-found

  log_info "Deleting CNPG harbor-pg cluster..."
  safe_delete clusters.postgresql.cnpg.io harbor-pg -n database --ignore-not-found

  log_info "Deleting ExternalSecrets in harbor namespace..."
  for es in harbor-admin-credentials harbor-db-credentials harbor-s3-credentials \
    harbor-valkey-credentials; do
    safe_delete externalsecret "$es" -n harbor --ignore-not-found
  done

  log_info "Deleting ExternalSecrets in database namespace..."
  safe_delete externalsecret harbor-pg-credentials -n database --ignore-not-found
  safe_delete externalsecret cnpg-minio-credentials -n database --ignore-not-found

  log_info "Deleting ExternalSecrets in minio namespace..."
  safe_delete externalsecret minio-root-credentials -n minio --ignore-not-found

  end_phase "Phase 2: Data Plane (CNPG, Valkey, ExternalSecrets)"
fi

# Phase 3: Delete Vault secrets, policies, auth roles, SecretStores
if [[ $PHASE_FROM -le 3 && $PHASE_TO -ge 3 ]]; then
  start_phase "Phase 3: Vault + SecretStores"

  if [[ -f "$VAULT_INIT_FILE" ]]; then
    root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")

    log_info "Deleting Vault KV secrets for Harbor..."
    for path in kv/services/harbor kv/services/harbor/valkey \
      kv/oidc/harbor kv/services/database/harbor-pg kv/services/database/cnpg-minio; do
      vault_teardown_exec "$root_token" kv metadata delete "$path"
    done

    # Delete Vault policies and auth roles for harbor namespace only.
    # minio and database policies are shared — cleaned up in Bundle 2 teardown.
    log_info "Deleting Vault policy eso-harbor..."
    vault_teardown_exec "$root_token" policy delete "eso-harbor"
    log_info "Deleting Vault K8s auth role eso-harbor..."
    vault_teardown_exec "$root_token" delete "auth/kubernetes/role/eso-harbor"
  else
    log_warn "Vault init file not found — skipping Vault cleanup"
  fi

  log_info "Deleting SecretStore in harbor namespace..."
  safe_delete secretstore vault-backend -n harbor --ignore-not-found

  end_phase "Phase 3: Vault + SecretStores"
fi

# Phase 4: Delete PVCs and namespace
if [[ $PHASE_FROM -le 4 && $PHASE_TO -ge 4 ]]; then
  start_phase "Phase 4: PVCs + Namespace"

  log_info "Deleting PVCs in harbor namespace..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] kubectl delete pvc --all -n harbor"
  else
    kubectl delete pvc --all -n harbor --wait=false 2>/dev/null || true
  fi

  log_info "Deleting harbor namespace..."
  safe_delete namespace harbor --ignore-not-found --wait=true --timeout=120s

  end_phase "Phase 4: PVCs + Namespace"
fi

log_ok "Bundle 4 (Harbor) teardown complete"
