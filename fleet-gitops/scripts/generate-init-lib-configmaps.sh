#!/usr/bin/env bash
set -euo pipefail

# generate-init-lib-configmaps.sh — Generate ConfigMap YAML files embedding init-lib.sh
# into each init bundle's manifests directory.
#
# Run after modifying scripts/init-lib.sh to sync all bundles.
# Called automatically by render-templates.sh.
#
# Usage:
#   ./scripts/generate-init-lib-configmaps.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_DIR="$(dirname "${SCRIPT_DIR}")"
INIT_LIB="${SCRIPT_DIR}/init-lib.sh"

[[ -f "${INIT_LIB}" ]] || { echo "ERROR: ${INIT_LIB} not found"; exit 1; }

# Find all *-init bundle directories (contain fleet.yaml + manifests/)
mapfile -t INIT_BUNDLES < <(find "${FLEET_DIR}" \
  -path "${FLEET_DIR}/rendered" -prune -o \
  -path "${FLEET_DIR}/.git" -prune -o \
  -path "${FLEET_DIR}/scripts" -prune -o \
  -type d -name '*-init' -print | sort)

generated=0
for bundle_dir in "${INIT_BUNDLES[@]}"; do
  manifests_dir="${bundle_dir}/manifests"
  fleet_yaml="${bundle_dir}/fleet.yaml"

  # Only process if it has a fleet.yaml (is a Fleet bundle)
  [[ -f "${fleet_yaml}" ]] || continue
  [[ -d "${manifests_dir}" ]] || continue

  # Extract namespace from fleet.yaml
  namespace=$(grep -oP 'defaultNamespace:\s*\K\S+' "${fleet_yaml}" 2>/dev/null || echo "default")

  # Generate ConfigMap YAML
  cm_file="${manifests_dir}/configmap-init-lib.yaml"
  {
    echo "# Auto-generated from scripts/init-lib.sh"
    echo "# Do not edit directly — run scripts/generate-init-lib-configmaps.sh"
    echo "---"
    echo "apiVersion: v1"
    echo "kind: ConfigMap"
    echo "metadata:"
    echo "  name: init-lib"
    echo "  namespace: ${namespace}"
    echo "data:"
    echo "  init-lib.sh: |"
    # Indent each line of init-lib.sh by 4 spaces for YAML block scalar
    sed 's/^/    /' "${INIT_LIB}"
  } > "${cm_file}"

  echo "[OK] Generated ${cm_file#"${FLEET_DIR}/"}"
  generated=$((generated + 1))
done

echo "[INFO] Generated ${generated} init-lib ConfigMaps"
