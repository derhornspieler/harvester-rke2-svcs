#!/usr/bin/env bash
set -euo pipefail

# push-bundles.sh — Package Fleet bundle directories as OCI artifacts
#                    and push to Harbor for OCI-first bootstrap
#
# Usage: ./push-bundles.sh [--version 1.0.0]
#
# Prerequisites: helm CLI, oras CLI (for OCI push), Harbor credentials

HARBOR="harbor.example.com"
VERSION="${1:-1.0.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_DIR="$(dirname "${SCRIPT_DIR}")"

BUNDLES=(
  "00-operators"
  "05-pki-secrets"
  "10-identity"
  "20-monitoring"
  "30-harbor"
  "40-gitops"
  "50-gitlab"
)

log() { echo "[$(date +%H:%M:%S)] $*"; }

for bundle in "${BUNDLES[@]}"; do
  bundle_dir="${FLEET_DIR}/${bundle}"
  if [[ ! -d "${bundle_dir}" ]]; then
    log "SKIP ${bundle} (directory not found)"
    continue
  fi

  log "Packaging ${bundle}:${VERSION}..."

  # Create a temporary Helm chart wrapper for the bundle
  tmpdir=$(mktemp -d)
  trap 'rm -rf "${tmpdir}"' EXIT

  # Chart.yaml
  cat > "${tmpdir}/Chart.yaml" <<EOF
apiVersion: v2
name: ${bundle}
version: ${VERSION}
description: Fleet bundle ${bundle}
type: application
EOF

  # Copy bundle contents as templates
  mkdir -p "${tmpdir}/templates"
  find "${bundle_dir}" -name "*.yaml" -o -name "*.yml" | while read -r f; do
    rel="${f#"${bundle_dir}/"}"
    target_dir="${tmpdir}/templates/$(dirname "${rel}")"
    mkdir -p "${target_dir}"
    cp "${f}" "${target_dir}/"
  done

  # Package and push
  helm package "${tmpdir}" -d "${tmpdir}"
  helm push "${tmpdir}/${bundle}-${VERSION}.tgz" "oci://${HARBOR}/fleet/"
  log "  Pushed oci://${HARBOR}/fleet/${bundle}:${VERSION}"

  rm -rf "${tmpdir}"
  trap - EXIT
done

log "All bundles pushed to oci://${HARBOR}/fleet/"
