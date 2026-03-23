#!/usr/bin/env bash
set -euo pipefail

# push-bundles.sh — Package raw-manifest Fleet bundles as Helm charts
#                    and push to oci://<HARBOR_HOST>/fleet/
#
# Usage: ./push-bundles.sh [--version 1.0.0]
#
# Prerequisites:
#   - helm CLI
#   - Harbor credentials in .env (HARBOR_USER / HARBOR_PASS)

###############################################################################
# Config
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_DIR="$(dirname "${SCRIPT_DIR}")"

# Source .env for credentials
if [[ -f "${FLEET_DIR}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${FLEET_DIR}/.env"
  set +a
fi
source "${SCRIPT_DIR}/lib/env-defaults.sh"

RENDERED_DIR="${FLEET_DIR}/rendered"

HARBOR="${HARBOR_HOST:?Set HARBOR_HOST in .env}"
HARBOR_USER="${HARBOR_USER:?Set HARBOR_USER in .env}"
HARBOR_PASS="${HARBOR_PASS:?Set HARBOR_PASS in .env}"
OCI_REGISTRY="oci://${HARBOR}/fleet"
VERSION="${BUNDLE_VERSION:-1.0.0}"

###############################################################################
# Raw-manifest bundles (no Helm chart reference in fleet.yaml)
# Format: "<dir-path>:<chart-name>"
###############################################################################
BUNDLES=(
  # 00-operators: cluster-wide operators and CRDs
  "00-operators/cluster-autoscaler:operators-cluster-autoscaler"
  "00-operators/overprovisioning:operators-overprovisioning"
  "00-operators/node-labeler:operators-node-labeler"
  "00-operators/storage-autoscaler:operators-storage-autoscaler"
  "00-operators/gateway-api-crds:operators-gateway-api-crds"
  # 05-pki-secrets: Vault, cert-manager, ESO bootstrap
  "05-pki-secrets/vault-init:pki-vault-init"
  "05-pki-secrets/vault-init-wait:pki-vault-init-wait"
  "05-pki-secrets/vault-unsealer:pki-vault-unsealer"
  "05-pki-secrets/vault-pki-issuer:pki-vault-pki-issuer"
  "05-pki-secrets/vault-bootstrap-store:pki-vault-bootstrap-store"
  # 10-identity: Keycloak + CNPG
  "10-identity/cnpg-keycloak:identity-cnpg-keycloak"
  "10-identity/keycloak-init:identity-keycloak-init"
  # identity-keycloak is now a Helm chart bundle (fleet.yaml + values.yaml)
  # — deployed via HelmOps referencing OCI chart directly, not pushed as a bundle
  "10-identity/keycloak-config:identity-keycloak-config"
  # 11-infra-auth: OAuth2-proxy for infra services
  "11-infra-auth/traefik-auth:infra-auth-traefik"
  "11-infra-auth/vault-auth:infra-auth-vault"
  "11-infra-auth/hubble-auth:infra-auth-hubble"
  # 15-dns: external-dns secrets
  "15-dns/external-dns-secrets:dns-external-dns-secrets"
  # 20-monitoring: observability stack
  "20-monitoring/monitoring-init:monitoring-init"
  "20-monitoring/cnpg-grafana:monitoring-cnpg-grafana"
  "20-monitoring/monitoring-secrets:monitoring-secrets"
  "20-monitoring/loki:monitoring-loki"
  "20-monitoring/alloy:monitoring-alloy"
  "20-monitoring/ingress-auth:monitoring-ingress-auth"
  # 30-harbor: registry + dependencies
  "30-harbor/harbor-init:harbor-init"
  "30-harbor/harbor-secrets:harbor-secrets"
  "30-harbor/minio:minio"
  "30-harbor/cnpg-harbor:harbor-cnpg-harbor"
  "30-harbor/valkey:harbor-valkey"
  "30-harbor/harbor-manifests:harbor-manifests"
  # 40-gitops: ArgoCD + Argo Rollouts + Argo Workflows
  "40-gitops/argocd-init:gitops-argocd-init"
  "40-gitops/rollouts-init:gitops-rollouts-init"
  "40-gitops/workflows-init:gitops-workflows-init"
  "40-gitops/argocd-credentials:gitops-argocd-credentials"
  "40-gitops/argocd-manifests:gitops-argocd-manifests"
  "40-gitops/argocd-gitlab-setup:gitops-argocd-gitlab-setup"
  "40-gitops/argo-rollouts-manifests:gitops-argo-rollouts-manifests"
  "40-gitops/argo-workflows-manifests:gitops-argo-workflows-manifests"
  "40-gitops/analysis-templates:gitops-analysis-templates"
  # 50-gitlab: GitLab EE + runners
  "50-gitlab/gitlab-init:gitlab-init"
  "50-gitlab/gitlab-cnpg:gitlab-cnpg-gitlab"
  "50-gitlab/gitlab-redis:gitlab-redis"
  "50-gitlab/gitlab-credentials:gitlab-credentials"
  "50-gitlab/gitlab-ready:gitlab-ready"
  "50-gitlab/gitlab-manifests:gitlab-manifests"
  "50-gitlab/gitlab-runners:gitlab-runners"
)

###############################################################################
# Helpers
###############################################################################
log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
die()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [--version <semver>]

Options:
  --version   Chart version to use (default: 1.0.0)
  -h, --help  Show this help
EOF
  exit 0
}

###############################################################################
# Argument parsing
###############################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ -n "${2:-}" ]] || die "--version requires a value"
      VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

###############################################################################
# Ensure Harbor "fleet" project exists
###############################################################################
ensure_harbor_project() {
  local api="https://${HARBOR}/api/v2.0"

  log "Checking Harbor project 'fleet'..."
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${HARBOR_USER}:${HARBOR_PASS}" \
    "${api}/projects?name=fleet")

  if [[ "${http_code}" == "200" ]]; then
    # Check if project actually exists in the response
    local count
    count=$(curl -s -u "${HARBOR_USER}:${HARBOR_PASS}" \
      "${api}/projects?name=fleet" | grep -c '"name":"fleet"' || true)
    if [[ "${count}" -gt 0 ]]; then
      log "Harbor project 'fleet' already exists."
      return 0
    fi
  fi

  log "Creating Harbor project 'fleet'..."
  local create_code
  create_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${HARBOR_USER}:${HARBOR_PASS}" \
    -X POST "${api}/projects" \
    -H "Content-Type: application/json" \
    -d '{"project_name":"fleet","public":false}')

  if [[ "${create_code}" =~ ^2[0-9]{2}$ ]]; then
    log "Harbor project 'fleet' created successfully."
  elif [[ "${create_code}" == "409" ]]; then
    log "Harbor project 'fleet' already exists (409 conflict)."
  else
    warn "Failed to create Harbor project 'fleet' (HTTP ${create_code}). Continuing anyway..."
  fi
}

###############################################################################
# Helm registry login
###############################################################################
helm_login() {
  log "Logging into Helm OCI registry ${HARBOR}..."
  echo "${HARBOR_PASS}" | helm registry login "${HARBOR}" \
    --username "${HARBOR_USER}" \
    --password-stdin
}

###############################################################################
# Package and push a single bundle
###############################################################################
push_bundle() {
  local bundle_relpath="$1"
  local chart_name="$2"
  local bundle_dir="${RENDERED_DIR}/${bundle_relpath}"
  local manifests_dir="${bundle_dir}/manifests"

  if [[ ! -d "${bundle_dir}" ]]; then
    warn "SKIP ${bundle_relpath} — directory not found: ${bundle_dir}"
    return 1
  fi

  if [[ ! -d "${manifests_dir}" ]]; then
    warn "SKIP ${bundle_relpath} — no manifests/ subdirectory"
    return 1
  fi

  log "Packaging ${chart_name}:${VERSION} from ${bundle_relpath}..."

  local tmpdir
  tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '${tmpdir}'" RETURN

  # --- Chart.yaml ---
  cat > "${tmpdir}/Chart.yaml" <<EOF
apiVersion: v2
name: ${chart_name}
version: ${VERSION}
description: Fleet bundle ${bundle_relpath}
type: application
EOF

  # --- templates/ — copy manifests preserving subdirectory structure ---
  mkdir -p "${tmpdir}/templates"
  while IFS= read -r -d '' src; do
    local rel="${src#"${manifests_dir}/"}"
    local dest_dir="${tmpdir}/templates/$(dirname "${rel}")"
    mkdir -p "${dest_dir}"
    cp "${src}" "${dest_dir}/"
  done < <(find "${manifests_dir}" \( -name "*.yaml" -o -name "*.yml" \) -print0)

  # --- Package ---
  helm package "${tmpdir}" --destination "${tmpdir}" >/dev/null
  local tgz="${tmpdir}/${chart_name}-${VERSION}.tgz"

  if [[ ! -f "${tgz}" ]]; then
    warn "helm package did not produce expected file: ${tgz}"
    return 1
  fi

  # --- Push ---
  helm push "${tgz}" "${OCI_REGISTRY}"
  log "  Pushed ${OCI_REGISTRY}/${chart_name}:${VERSION}"
}

###############################################################################
# Main
###############################################################################
main() {
  log "=== push-bundles.sh — version ${VERSION} ==="

  # Render templates (substitutes env vars into YAML)
  log "Rendering templates..."
  "${SCRIPT_DIR}/render-templates.sh"

  # Inject spec-hash annotations into rendered Job manifests
  log "Computing Job spec hashes..."
  "${SCRIPT_DIR}/compute-job-hashes.sh"

  ensure_harbor_project
  helm_login

  local failed=0
  local pushed=0

  for entry in "${BUNDLES[@]}"; do
    local relpath="${entry%%:*}"
    local chart_name="${entry##*:}"

    if push_bundle "${relpath}" "${chart_name}"; then
      pushed=$((pushed + 1))
    else
      failed=$((failed + 1))
    fi
  done

  log "=== Done: ${pushed} pushed, ${failed} skipped/failed ==="

  if [[ "${failed}" -gt 0 ]]; then
    return 1
  fi
}

main "$@"
