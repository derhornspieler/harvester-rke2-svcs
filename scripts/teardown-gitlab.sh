#!/usr/bin/env bash
# teardown-gitlab.sh — Tear down Bundle 6 (GitLab + Runners)
# Reverse of deploy-gitlab.sh: runners, Helm release, CNPG, Redis, ESO, Vault, namespaces.
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

Tear down Bundle 6: GitLab + Runners.

Options:
  --phase N       Run only phase N
  --from N        Start from phase N (default: 1)
  --to N          Stop after phase N (default: 4)
  --dry-run       Print what would be done without making changes
  --force         Skip dependency guards
  -h, --help      Show this help

Phases:
  1  Helm releases         Delete GitLab, runner Helm releases, Gateway/TCPRoute, monitoring
  2  Data plane            Delete CNPG gitlab-postgresql, Redis CRs, ExternalSecrets, Vault secrets
  3  Vault + SecretStores  Delete Vault policies, auth roles, SecretStores, PVCs
  4  Namespaces            Delete gitlab, gitlab-runners namespaces
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

# Dry-run wrapper: prints the command instead of executing it
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] $*"
  else
    "$@"
  fi
}

# Safe delete: ignore errors if resource doesn't exist
safe_delete() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] kubectl delete $*"
  else
    kubectl delete "$@" 2>/dev/null || true
  fi
}

# Vault exec wrapper with dry-run support
vault_teardown_exec() {
  local root_token="$1"
  shift
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] vault $*"
  else
    vault_exec "$root_token" "$@" 2>/dev/null || true
  fi
}

# No dependency guard needed — Bundle 6 is top of stack
# FORCE is parsed for CLI consistency across all teardown scripts
export FORCE

# Phase 1: Delete Helm releases, Gateway, TCPRoute, monitoring
if [[ $PHASE_FROM -le 1 && $PHASE_TO -ge 1 ]]; then
  start_phase "Phase 1: Helm Releases + Ingress + Monitoring"

  log_info "Deleting monitoring resources..."
  safe_delete -k "${REPO_ROOT}/services/gitlab/monitoring/" --ignore-not-found

  log_info "Deleting VolumeAutoscalers..."
  safe_delete -f "${REPO_ROOT}/services/gitlab/volume-autoscalers.yaml" --ignore-not-found

  log_info "Deleting GitLab runner Helm releases..."
  run helm uninstall gitlab-runner-group -n gitlab-runners --wait 2>/dev/null || true
  run helm uninstall gitlab-runner-security -n gitlab-runners --wait 2>/dev/null || true
  run helm uninstall gitlab-runner-shared -n gitlab-runners --wait 2>/dev/null || true

  log_info "Deleting GitLab Helm release..."
  run helm uninstall gitlab -n gitlab --wait --timeout 10m 2>/dev/null || true

  log_info "Deleting Gateway and TCPRoute..."
  safe_delete tcproute gitlab-ssh -n gitlab --ignore-not-found
  safe_delete gateway gitlab -n gitlab --ignore-not-found

  end_phase "Phase 1: Helm Releases + Ingress + Monitoring"
fi

# Phase 2: Delete CNPG cluster, Redis, ExternalSecrets, Vault KV secrets
if [[ $PHASE_FROM -le 2 && $PHASE_TO -ge 2 ]]; then
  start_phase "Phase 2: Data Plane (CNPG, Redis, ESO, Vault secrets)"

  log_info "Deleting Redis Sentinel and Replication CRs..."
  safe_delete redissentinel gitlab-redis -n gitlab --ignore-not-found
  safe_delete redisreplication gitlab-redis -n gitlab --ignore-not-found

  log_info "Deleting PgBouncer poolers..."
  safe_delete -f "${REPO_ROOT}/services/gitlab/pgbouncer-poolers.yaml" --ignore-not-found

  log_info "Deleting CNPG scheduled backup..."
  safe_delete -f "${REPO_ROOT}/services/gitlab/cloudnativepg-scheduled-backup.yaml" --ignore-not-found

  log_info "Deleting CNPG gitlab-postgresql cluster..."
  safe_delete clusters.postgresql.cnpg.io gitlab-postgresql -n database --ignore-not-found

  log_info "Deleting ExternalSecrets in gitlab namespace..."
  for es in gitlab-gitaly-secret gitlab-praefect-dbsecret gitlab-praefect-secret \
    gitlab-redis-credentials gitlab-oidc-secret gitlab-gitlab-initial-root-password \
    gitlab-minio-storage; do
    safe_delete externalsecret "$es" -n gitlab --ignore-not-found
  done

  log_info "Deleting ExternalSecrets in gitlab-runners namespace..."
  safe_delete externalsecret harbor-ci-push -n gitlab-runners --ignore-not-found

  # Delete Vault KV secrets
  if [[ -f "$VAULT_INIT_FILE" ]]; then
    root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")
    log_info "Deleting Vault KV secrets for GitLab..."
    for path in kv/services/gitlab kv/services/gitlab/redis kv/services/gitlab/gitaly-secret \
      kv/services/gitlab/praefect-dbsecret kv/services/gitlab/praefect-secret \
      kv/services/gitlab/initial-root-password kv/services/gitlab/oidc-secret \
      kv/services/gitlab/minio-storage kv/oidc/gitlab kv/ci/harbor-push \
      kv/services/database/gitlab-pg kv/services/database/cnpg-minio-gitlab; do
      vault_teardown_exec "$root_token" kv metadata delete "$path"
    done
  else
    log_warn "Vault init file not found — skipping Vault secret cleanup"
  fi

  end_phase "Phase 2: Data Plane (CNPG, Redis, ESO, Vault secrets)"
fi

# Phase 3: Delete Vault policies, auth roles, SecretStores, PVCs
if [[ $PHASE_FROM -le 3 && $PHASE_TO -ge 3 ]]; then
  start_phase "Phase 3: Vault Policies + SecretStores + PVCs"

  if [[ -f "$VAULT_INIT_FILE" ]]; then
    root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")
    for ns in gitlab gitlab-runners; do
      log_info "Deleting Vault policy eso-${ns}..."
      vault_teardown_exec "$root_token" policy delete "eso-${ns}"
      log_info "Deleting Vault K8s auth role eso-${ns}..."
      vault_teardown_exec "$root_token" delete "auth/kubernetes/role/eso-${ns}"
    done
  else
    log_warn "Vault init file not found — skipping Vault policy/role cleanup"
  fi

  log_info "Deleting SecretStores..."
  safe_delete secretstore vault-backend -n gitlab --ignore-not-found
  safe_delete secretstore vault-backend -n gitlab-runners --ignore-not-found

  log_info "Deleting PVCs in gitlab namespace..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] kubectl delete pvc --all -n gitlab"
    log_info "[DRY-RUN] kubectl delete pvc --all -n gitlab-runners"
  else
    kubectl delete pvc --all -n gitlab --wait=false 2>/dev/null || true
    kubectl delete pvc --all -n gitlab-runners --wait=false 2>/dev/null || true
  fi

  end_phase "Phase 3: Vault Policies + SecretStores + PVCs"
fi

# Phase 4: Delete namespaces
if [[ $PHASE_FROM -le 4 && $PHASE_TO -ge 4 ]]; then
  start_phase "Phase 4: Namespaces"

  log_info "Deleting gitlab-runners namespace..."
  safe_delete namespace gitlab-runners --ignore-not-found --wait=true --timeout=120s
  log_info "Deleting gitlab namespace..."
  safe_delete namespace gitlab --ignore-not-found --wait=true --timeout=120s

  end_phase "Phase 4: Namespaces"
fi

log_ok "Bundle 6 (GitLab) teardown complete"
