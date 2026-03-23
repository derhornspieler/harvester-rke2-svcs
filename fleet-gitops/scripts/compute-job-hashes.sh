#!/usr/bin/env bash
# =============================================================================
# compute-job-hashes.sh — Inject spec-hash annotations into rendered Job manifests
# =============================================================================
# Computes a SHA-256 hash of each rendered Job manifest file and injects it as
# a fleet.example.com/spec-hash annotation on the Job resource. This allows
# cleanup_completed_init_jobs() to only delete Jobs whose spec actually changed.
#
# Called by push-bundles.sh AFTER render-templates.sh, BEFORE packaging.
#
# The hash is computed from the file BEFORE annotation injection (excludes any
# existing spec-hash line) to avoid circular dependency.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_DIR="$(dirname "${SCRIPT_DIR}")"
RENDERED_DIR="${FLEET_DIR}/rendered"

# Map: "namespace/job-name" → rendered manifest file (relative to rendered/)
declare -A JOB_MANIFEST_FILES=(
  ["vault/vault-init"]="05-pki-secrets/vault-init/manifests/vault-init-job.yaml"
  ["vault/vault-init-wait"]="05-pki-secrets/vault-init-wait/manifests/vault-init-wait-job.yaml"
  ["keycloak/keycloak-init"]="10-identity/keycloak-init/manifests/init-job.yaml"
  ["keycloak/keycloak-config"]="10-identity/keycloak-config/manifests/keycloak-config-job.yaml"
  ["database/database-init"]="10-identity/cnpg-keycloak/manifests/init-job.yaml"
  ["monitoring/monitoring-init"]="20-monitoring/monitoring-init/manifests/monitoring-init-job.yaml"
  ["harbor/harbor-init"]="30-harbor/harbor-init/manifests/harbor-init-job.yaml"
  ["harbor/harbor-oidc-setup"]="30-harbor/harbor-manifests/manifests/harbor-oidc-config.yaml"
  ["minio/minio-init"]="30-harbor/minio/manifests/minio-init-job.yaml"
  ["argocd/argocd-init"]="40-gitops/argocd-init/manifests/argocd-init-job.yaml"
  ["argocd/argocd-gitlab-setup"]="40-gitops/argocd-gitlab-setup/manifests/argocd-gitlab-setup.yaml"
  ["argo-rollouts/rollouts-init"]="40-gitops/rollouts-init/manifests/rollouts-init-job.yaml"
  ["argo-workflows/workflows-init"]="40-gitops/workflows-init/manifests/workflows-init-job.yaml"
  ["gitlab/gitlab-init"]="50-gitlab/gitlab-init/manifests/gitlab-init-job.yaml"
  ["gitlab/gitlab-ready"]="50-gitlab/gitlab-ready/manifests/gitlab-ready-job.yaml"
  ["gitlab/vault-jwt-auth-setup"]="50-gitlab/gitlab-manifests/manifests/vault-jwt-auth-setup.yaml"
  ["gitlab/gitlab-admin-setup"]="50-gitlab/gitlab-manifests/manifests/gitlab-admin-setup.yaml"
  ["gitlab-runners/runner-secrets-setup"]="50-gitlab/gitlab-runners/manifests/runner-secrets-setup.yaml"
)

compute_spec_hash() {
  # Hash the file excluding any existing spec-hash annotation line
  grep -v 'fleet\.aegisgroup\.ch/spec-hash:' "$1" | sha256sum | awk '{print $1}'
}

injected=0
skipped=0

for entry in "${!JOB_MANIFEST_FILES[@]}"; do
  file="${RENDERED_DIR}/${JOB_MANIFEST_FILES[${entry}]}"
  if [[ ! -f "${file}" ]]; then
    echo "[WARN] ${file} not found, skipping ${entry}" >&2
    skipped=$((skipped + 1))
    continue
  fi

  hash=$(compute_spec_hash "${file}")
  python3 "${SCRIPT_DIR}/lib/inject-spec-hash.py" "${file}" "${hash}"
  injected=$((injected + 1))
done

echo "[OK] Injected spec-hash into ${injected} Job manifests (${skipped} skipped)" >&2
