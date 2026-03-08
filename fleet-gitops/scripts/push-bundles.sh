#!/usr/bin/env bash
set -euo pipefail

# push-bundles.sh — Package raw-manifest Fleet bundles as Helm charts
#                    and push to oci://harbor.aegisgroup.ch/fleet/
#
# Usage: ./push-bundles.sh [--version 1.0.0]
#
# Prerequisites:
#   - helm CLI
#   - Harbor credentials (HARBOR_USER / HARBOR_PASS or defaults to admin/Harbor12345)

###############################################################################
# Config
###############################################################################
HARBOR="harbor.aegisgroup.ch"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
OCI_REGISTRY="oci://${HARBOR}/fleet"
VERSION="${BUNDLE_VERSION:-1.0.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_DIR="$(dirname "${SCRIPT_DIR}")"

###############################################################################
# Raw-manifest bundles (no Helm chart reference in fleet.yaml)
# Format: "<dir-path>:<chart-name>"
###############################################################################
BUNDLES=(
  "00-operators/cluster-autoscaler:operators-cluster-autoscaler"
  "00-operators/node-labeler:operators-node-labeler"
  "00-operators/storage-autoscaler:operators-storage-autoscaler"
  "05-pki-secrets/vault-init:pki-vault-init"
  "05-pki-secrets/vault-unsealer:pki-vault-unsealer"
  "05-pki-secrets/vault-pki-issuer:pki-vault-pki-issuer"
  "10-identity/cnpg-keycloak:identity-cnpg-keycloak"
  "10-identity/keycloak:identity-keycloak"
  "10-identity/keycloak-config:identity-keycloak-config"
  "20-monitoring/cnpg-grafana:monitoring-cnpg-grafana"
  "20-monitoring/monitoring-secrets:monitoring-secrets"
  "20-monitoring/loki:monitoring-loki"
  "20-monitoring/alloy:monitoring-alloy"
  "20-monitoring/ingress-auth:monitoring-ingress-auth"
  "30-harbor/minio:minio"
  "30-harbor/cnpg-harbor:harbor-cnpg-harbor"
  "30-harbor/valkey:harbor-valkey"
  "30-harbor/harbor-manifests:harbor-manifests"
  "40-gitops/argocd-manifests:gitops-argocd-manifests"
  "40-gitops/argo-rollouts-manifests:gitops-argo-rollouts-manifests"
  "40-gitops/argo-workflows-manifests:gitops-argo-workflows-manifests"
  "40-gitops/analysis-templates:gitops-analysis-templates"
  "50-gitlab/cnpg-gitlab:gitlab-cnpg-gitlab"
  "50-gitlab/redis:gitlab-redis"
  "50-gitlab/gitlab-manifests:gitlab-manifests"
  "50-gitlab/runners:gitlab-runners"
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
  local bundle_dir="${FLEET_DIR}/${bundle_relpath}"
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
