#!/usr/bin/env bash
# =============================================================================
# cleanup-completed-jobs.sh — Delete completed Fleet-managed Jobs
# =============================================================================
# Kubernetes Jobs are immutable after creation. When Fleet pushes an updated
# Job spec, it cannot patch completed Jobs, causing ErrApplied state.
#
# This script deletes completed Jobs so Fleet can recreate them with the
# latest spec on the next reconciliation cycle.
#
# Usage:
#   ./cleanup-completed-jobs.sh              # Delete all completed Fleet Jobs
#   ./cleanup-completed-jobs.sh --dry-run    # Show what would be deleted
#   ./cleanup-completed-jobs.sh vault-init   # Delete only a specific Job
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Fleet-managed Jobs (namespace/name) — auto-discovered from bundle manifests
# ---------------------------------------------------------------------------
FLEET_JOBS=(
  "vault/vault-init"
  "vault/vault-init-wait"
  "keycloak/keycloak-config"
  "keycloak/keycloak-ldap-federation"
  "monitoring/monitoring-init"
  "minio/minio-init"
  "harbor/harbor-init"
  "harbor/harbor-oidc-setup"
  "argocd/argocd-init"
  "argocd/argocd-gitlab-setup"
  "argo-rollouts/rollouts-init"
  "argo-workflows/workflows-init"
  "gitlab/gitlab-init"
  "gitlab/gitlab-ready"
  "gitlab/vault-jwt-auth-setup"
  "gitlab/gitlab-admin-setup"
  "gitlab-runners/runner-secrets-setup"
)

# ---------------------------------------------------------------------------
# Colors & flags
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DRY_RUN=false
FILTER=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --help|-h)
      echo "Usage: $0 [--dry-run] [job-name-filter]"
      echo ""
      echo "Deletes completed Fleet-managed Jobs so Fleet can recreate them."
      echo ""
      echo "Options:"
      echo "  --dry-run    Show what would be deleted without deleting"
      echo "  job-name     Only delete Jobs matching this name (partial match)"
      exit 0
      ;;
    *) FILTER="$arg" ;;
  esac
done

# ---------------------------------------------------------------------------
# Kubeconfig
# ---------------------------------------------------------------------------
export KUBECONFIG="${KUBECONFIG:-/tmp/rke2-kubeconfig.yaml}"

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Cannot connect to cluster. Check KUBECONFIG=${KUBECONFIG}"
  exit 1
fi

# ---------------------------------------------------------------------------
# Delete completed Jobs
# ---------------------------------------------------------------------------
deleted=0
skipped=0

for entry in "${FLEET_JOBS[@]}"; do
  ns="${entry%%/*}"
  name="${entry##*/}"

  # Apply name filter if provided
  if [[ -n "$FILTER" ]] && [[ "$name" != *"$FILTER"* ]]; then
    continue
  fi

  # Check if Job exists and is complete
  status=$(kubectl get job "$name" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "")

  if [[ "$status" == "True" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      echo -e "${YELLOW}[DRY-RUN]${NC} Would delete completed Job ${BLUE}${ns}/${name}${NC}"
    else
      kubectl delete job "$name" -n "$ns"
      echo -e "${GREEN}[DELETED]${NC} ${ns}/${name}"
    fi
    deleted=$((deleted + 1))
  else
    # Check if it exists but is still running
    exists=$(kubectl get job "$name" -n "$ns" -o name 2>/dev/null || echo "")
    if [[ -n "$exists" ]]; then
      echo -e "${BLUE}[SKIP]${NC}    ${ns}/${name} (not completed)"
      skipped=$((skipped + 1))
    fi
  fi
done

echo ""
if [[ "$DRY_RUN" == "true" ]]; then
  echo -e "Dry run: ${YELLOW}${deleted}${NC} would be deleted, ${BLUE}${skipped}${NC} skipped (not completed)"
else
  echo -e "Cleaned up: ${GREEN}${deleted}${NC} deleted, ${BLUE}${skipped}${NC} skipped (not completed)"
fi
