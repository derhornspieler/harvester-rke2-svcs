#!/usr/bin/env bash
set -euo pipefail

# deploy-fleet-bundles.sh — Create Fleet Bundle CRs on Rancher management cluster
#
# Reads fleet.yaml files from fleet-gitops/ and creates Bundle CRs via
# Rancher Steve API. Handles both Helm OCI chart bundles and raw manifest
# bundles. Respects dependency ordering via dependsOn labels.
#
# Usage:
#   ./deploy-fleet-bundles.sh                    # Deploy all bundles
#   ./deploy-fleet-bundles.sh --bundle 00-operators  # Deploy single group
#   ./deploy-fleet-bundles.sh --dry-run          # Show Bundle CRs without applying
#   ./deploy-fleet-bundles.sh --delete           # Remove all Fleet bundles
#   ./deploy-fleet-bundles.sh --status           # Show bundle deployment status
#
# Prerequisites:
#   - Rancher API access (reads from .env file or environment variables)
#   - Helm charts already pushed to Harbor (run push-charts.sh first)
#   - Root CA secret pre-seeded on rke2-prod (for vault-init)

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_DIR="$(dirname "${SCRIPT_DIR}")"
# --- Logging ---
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
die()       { log_error "$*"; exit 1; }

# --- Config from .env or environment ---
load_config() {
  local env_file="${FLEET_DIR}/.env"
  if [[ -f "${env_file}" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${env_file}"
    set +a
  fi

  [[ -n "${RANCHER_URL:-}" ]] || die "RANCHER_URL not set (export it or add to ${env_file})"
  [[ -n "${RANCHER_TOKEN:-}" ]] || die "RANCHER_TOKEN not set (export it or add to ${env_file})"
}

# --- Rancher API ---
rancher_api() {
  local method="$1" path="$2"
  shift 2
  curl -sk -X "${method}" \
    -H "Authorization: Bearer ${RANCHER_TOKEN}" \
    -H "Content-Type: application/json" \
    "${RANCHER_URL}${path}" "$@"
}

# --- Bundle definitions ---
# Each entry: name|fleet_dir|depends_on (comma-separated bundle names, empty = none)
# Order matters — deploy sequentially respecting dependencies
BUNDLE_DEFS=(
  # 00-operators (no dependencies)
  "operators-cnpg|00-operators/cnpg-operator|"
  "operators-redis|00-operators/redis-operator|"
  "operators-node-labeler|00-operators/node-labeler|"
  "operators-storage-autoscaler|00-operators/storage-autoscaler|"
  "operators-cluster-autoscaler|00-operators/cluster-autoscaler|"

  # 05-pki-secrets (depends on operators)
  "pki-cert-manager|05-pki-secrets/cert-manager|operators-cnpg"
  "pki-vault|05-pki-secrets/vault|operators-cnpg"
  "pki-vault-init|05-pki-secrets/vault-init|pki-vault"
  "pki-vault-pki-issuer|05-pki-secrets/vault-pki-issuer|pki-vault-init"
  "pki-external-secrets|05-pki-secrets/external-secrets|pki-vault-init"

  # 10-identity (depends on pki)
  "identity-cnpg-keycloak|10-identity/cnpg-keycloak|pki-external-secrets,operators-cnpg"
  "identity-keycloak|10-identity/keycloak|identity-cnpg-keycloak"
  "identity-keycloak-config|10-identity/keycloak-config|identity-keycloak"

  # 20-monitoring (depends on pki + identity)
  "monitoring-loki|20-monitoring/loki|pki-external-secrets"
  "monitoring-alloy|20-monitoring/alloy|pki-external-secrets"
  "monitoring-prometheus-stack|20-monitoring/kube-prometheus-stack|pki-external-secrets"
  "monitoring-ingress-auth|20-monitoring/ingress-auth|monitoring-prometheus-stack,identity-keycloak-config"

  # 30-harbor (depends on pki + identity)
  "harbor-minio|30-harbor/minio|pki-external-secrets"
  "harbor-cnpg|30-harbor/cnpg-harbor|pki-external-secrets,operators-cnpg"
  "harbor-valkey|30-harbor/valkey|pki-external-secrets,operators-redis"
  "harbor-core|30-harbor/harbor|harbor-minio,harbor-cnpg,harbor-valkey,identity-keycloak-config"

  # 40-gitops (depends on pki + identity)
  "gitops-argocd|40-gitops/argocd|pki-external-secrets,identity-keycloak-config"
  "gitops-argo-rollouts|40-gitops/argo-rollouts|pki-external-secrets,identity-keycloak-config"
  "gitops-argo-workflows|40-gitops/argo-workflows|pki-external-secrets,identity-keycloak-config"
  "gitops-analysis-templates|40-gitops/analysis-templates|gitops-argocd"

  # 50-gitlab (depends on pki + identity + harbor)
  "gitlab-cnpg|50-gitlab/cnpg-gitlab|pki-external-secrets,operators-cnpg"
  "gitlab-redis|50-gitlab/redis|pki-external-secrets,operators-redis"
  "gitlab-core|50-gitlab/gitlab|gitlab-cnpg,gitlab-redis,harbor-core,identity-keycloak-config"
  "gitlab-runners|50-gitlab/runners|gitlab-core"
)

# --- Build Bundle CR JSON ---
# Args: bundle_name fleet_dir depends_on output_file
build_bundle_cr() {
  local bundle_name="$1"
  local fleet_dir="$2"
  local depends_on="$3"
  local output_file="$4"
  local full_path="${FLEET_DIR}/${fleet_dir}"
  local fleet_yaml="${full_path}/fleet.yaml"

  [[ -f "${fleet_yaml}" ]] || die "fleet.yaml not found at ${fleet_yaml}"

  # Parse fleet.yaml
  local default_ns helm_chart helm_version helm_release
  default_ns=$(python3 -c "
import yaml, sys
with open('${fleet_yaml}') as f:
    d = yaml.safe_load(f)
print(d.get('defaultNamespace', ''))
" 2>/dev/null || echo "")

  helm_chart=$(python3 -c "
import yaml, sys
with open('${fleet_yaml}') as f:
    d = yaml.safe_load(f)
h = d.get('helm', {})
print(h.get('chart', ''))
" 2>/dev/null || echo "")

  helm_version=$(python3 -c "
import yaml, sys
with open('${fleet_yaml}') as f:
    d = yaml.safe_load(f)
h = d.get('helm', {})
print(h.get('version', ''))
" 2>/dev/null || echo "")

  helm_release=$(python3 -c "
import yaml, sys
with open('${fleet_yaml}') as f:
    d = yaml.safe_load(f)
h = d.get('helm', {})
print(h.get('releaseName', ''))
" 2>/dev/null || echo "")

  # Build dependsOn array
  local deps_json="[]"
  if [[ -n "${depends_on}" ]]; then
    deps_json=$(echo "${depends_on}" | tr ',' '\n' | jq -Rn '
      [inputs | select(length > 0) | {name: .}]
    ')
  fi

  # Start building the Bundle CR
  local bundle_json

  if [[ -n "${helm_chart}" ]]; then
    # --- Helm OCI bundle ---
    # Read values.yaml if present
    local values_json="{}"
    local values_file="${full_path}/values.yaml"
    if [[ -f "${values_file}" ]]; then
      values_json=$(python3 -c "
import yaml, json, sys
with open('${values_file}') as f:
    d = yaml.safe_load(f)
print(json.dumps(d if d else {}))
")
    fi

    # Check for additional manifest files alongside the Helm chart
    local resources_file
    resources_file=$(mktemp /tmp/fleet-resources-XXXXXX.json)
    local manifests_dir="${full_path}/manifests"
    if [[ -d "${manifests_dir}" ]]; then
      build_resources_json "${manifests_dir}" > "${resources_file}"
    else
      echo '[]' > "${resources_file}"
    fi

    local values_file_tmp
    values_file_tmp=$(mktemp /tmp/fleet-values-XXXXXX.json)
    echo "${values_json}" > "${values_file_tmp}"

    jq -n \
      --arg name "${bundle_name}" \
      --arg ns "${default_ns}" \
      --arg chart "${helm_chart}" \
      --arg version "${helm_version}" \
      --arg release "${helm_release}" \
      --slurpfile values "${values_file_tmp}" \
      --argjson deps "${deps_json}" \
      --slurpfile resources "${resources_file}" \
      '{
        apiVersion: "fleet.cattle.io/v1alpha1",
        kind: "Bundle",
        metadata: {
          name: $name,
          namespace: "fleet-default",
          labels: {
            "fleet.cattle.io/bundle-name": $name
          }
        },
        spec: {
          targets: [{clusterName: "rke2-prod"}],
          dependsOn: $deps,
          defaultNamespace: $ns,
          helm: {
            chart: $chart,
            version: $version,
            releaseName: $release,
            values: $values[0]
          },
          resources: $resources[0]
        }
      }' > "${output_file}"

    rm -f "${resources_file}" "${values_file_tmp}"

  else
    # --- Raw manifest bundle ---
    local manifests_dir="${full_path}/manifests"
    if [[ ! -d "${manifests_dir}" ]]; then
      # No manifests dir — look for YAML files directly in the directory
      manifests_dir="${full_path}"
    fi

    local resources_file
    resources_file=$(mktemp /tmp/fleet-resources-XXXXXX.json)
    build_resources_json "${manifests_dir}" > "${resources_file}"

    jq -n \
      --arg name "${bundle_name}" \
      --arg ns "${default_ns}" \
      --argjson deps "${deps_json}" \
      --slurpfile resources "${resources_file}" \
      '{
        apiVersion: "fleet.cattle.io/v1alpha1",
        kind: "Bundle",
        metadata: {
          name: $name,
          namespace: "fleet-default",
          labels: {
            "fleet.cattle.io/bundle-name": $name
          }
        },
        spec: {
          targets: [{clusterName: "rke2-prod"}],
          dependsOn: $deps,
          defaultNamespace: $ns,
          resources: $resources[0]
        }
      }' > "${output_file}"

    rm -f "${resources_file}"
  fi
}

# --- Build resources JSON from a directory of YAML files ---
# Writes JSON array to stdout. Uses temp file to avoid ARG_MAX limits.
build_resources_json() {
  local dir="$1"
  local tmpfile
  tmpfile=$(mktemp /tmp/fleet-res-build-XXXXXX.json)
  echo '[]' > "${tmpfile}"

  while IFS= read -r -d '' yaml_file; do
    local rel_path="${yaml_file#"${dir}/"}"

    # Skip fleet.yaml itself
    [[ "${rel_path}" == "fleet.yaml" ]] && continue

    # Use --rawfile + slurpfile to avoid argument list too long
    jq --arg name "${rel_path}" \
       --rawfile content "${yaml_file}" \
       '. + [{name: $name, content: $content}]' \
       "${tmpfile}" > "${tmpfile}.tmp" && mv "${tmpfile}.tmp" "${tmpfile}"
  done < <(find "${dir}" -name "*.yaml" -o -name "*.yml" | sort | tr '\n' '\0')

  cat "${tmpfile}"
  rm -f "${tmpfile}" "${tmpfile}.tmp"
}

# --- Create a single Bundle CR ---
create_bundle() {
  local bundle_name="$1"
  local fleet_dir="$2"
  local depends_on="$3"

  log_info "Creating bundle: ${bundle_name}..."

  # Use temp file throughout to avoid ARG_MAX limits on large bundles
  local tmpfile
  tmpfile=$(mktemp /tmp/fleet-bundle-XXXXXX.json)
  trap 'rm -f "${tmpfile}"' RETURN

  build_bundle_cr "${bundle_name}" "${fleet_dir}" "${depends_on}" "${tmpfile}"

  if [[ "${DRY_RUN}" == true ]]; then
    jq '.' "${tmpfile}"
    log_ok "Dry run: ${bundle_name}"
    return 0
  fi

  # Check if bundle already exists
  local existing
  existing=$(rancher_api GET "/v1/fleet.cattle.io.bundles/fleet-default/${bundle_name}" 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('metadata',{}).get('name',''))" 2>/dev/null || echo "")

  if [[ "${existing}" == "${bundle_name}" ]]; then
    log_warn "Bundle ${bundle_name} already exists — updating"
    # GET current resourceVersion for PUT
    local rv
    rv=$(rancher_api GET "/v1/fleet.cattle.io.bundles/fleet-default/${bundle_name}" | \
      python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['resourceVersion'])")
    jq --arg rv "${rv}" '.metadata.resourceVersion = $rv' "${tmpfile}" > "${tmpfile}.tmp" && mv "${tmpfile}.tmp" "${tmpfile}"
    local resp
    resp=$(rancher_api PUT "/v1/fleet.cattle.io.bundles/fleet-default/${bundle_name}" -d "@${tmpfile}")
    local err
    err=$(echo "${resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message',''))" 2>/dev/null || echo "")
    if [[ -n "${err}" ]]; then
      log_error "Failed to update ${bundle_name}: ${err}"
      return 1
    fi
    log_ok "Updated: ${bundle_name}"
  else
    local resp
    resp=$(rancher_api POST "/v1/fleet.cattle.io.bundles" -d "@${tmpfile}")
    local created
    created=$(echo "${resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('metadata',{}).get('name',''))" 2>/dev/null || echo "")
    if [[ "${created}" != "${bundle_name}" ]]; then
      local err
      err=$(echo "${resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message', d.get('reason','unknown')))" 2>/dev/null || echo "unknown")
      log_error "Failed to create ${bundle_name}: ${err}"
      echo "${resp}" | jq '.' 2>/dev/null || echo "${resp}"
      return 1
    fi
    log_ok "Created: ${bundle_name}"
  fi
}

# --- Wait for a bundle to be ready ---
wait_for_bundle() {
  local bundle_name="$1"
  local timeout="${2:-300}"
  local start_time
  start_time=$(date +%s)

  while true; do
    local elapsed=$(( $(date +%s) - start_time ))
    if (( elapsed > timeout )); then
      log_error "Timeout waiting for ${bundle_name} (${timeout}s)"
      return 1
    fi

    local state
    state=$(rancher_api GET "/v1/fleet.cattle.io.bundles/fleet-default/${bundle_name}" 2>/dev/null | \
      python3 -c "
import sys,json
d=json.load(sys.stdin)
summary=d.get('status',{}).get('summary',{})
ready=summary.get('ready',0)
desired=summary.get('desiredReady',0)
print(f'{ready}/{desired}')
" 2>/dev/null || echo "0/0")

    if [[ "${state}" == "1/1" ]]; then
      return 0
    fi

    sleep 5
  done
}

# --- Delete all Fleet bundles ---
delete_bundles() {
  log_info "Deleting all Fleet bundles..."
  for entry in "${BUNDLE_DEFS[@]}"; do
    IFS='|' read -r name _ _ <<< "${entry}"
    local existing
    existing=$(rancher_api GET "/v1/fleet.cattle.io.bundles/fleet-default/${name}" 2>/dev/null | \
      python3 -c "import sys,json; print(json.load(sys.stdin).get('metadata',{}).get('name',''))" 2>/dev/null || echo "")
    if [[ "${existing}" == "${name}" ]]; then
      rancher_api DELETE "/v1/fleet.cattle.io.bundles/fleet-default/${name}" > /dev/null 2>&1
      log_ok "Deleted: ${name}"
    fi
  done
}

# --- Show bundle status ---
show_status() {
  echo -e "${BOLD}Fleet Bundle Status:${NC}"
  printf "%-35s %-12s %-8s %s\n" "BUNDLE" "STATE" "READY" "MESSAGE"
  printf "%-35s %-12s %-8s %s\n" "------" "-----" "-----" "-------"

  for entry in "${BUNDLE_DEFS[@]}"; do
    IFS='|' read -r name _ _ <<< "${entry}"
    local info
    info=$(rancher_api GET "/v1/fleet.cattle.io.bundles/fleet-default/${name}" 2>/dev/null | \
      python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    summary=d.get('status',{}).get('summary',{})
    ready=summary.get('ready',0)
    desired=summary.get('desiredReady',0)
    conditions=d.get('status',{}).get('conditions',[])
    state='Unknown'
    msg=''
    for c in conditions:
        if c.get('type')=='Ready':
            state='Ready' if c.get('status')=='True' else 'NotReady'
            msg=c.get('message','')[:60]
    print(f'{state}|{ready}/{desired}|{msg}')
except:
    print('NotFound|0/0|')
" 2>/dev/null || echo "Error|0/0|")

    IFS='|' read -r state ready msg <<< "${info}"
    local color="${RED}"
    [[ "${state}" == "Ready" ]] && color="${GREEN}"
    [[ "${state}" == "NotFound" ]] && color="${YELLOW}"

    printf "%-35s ${color}%-12s${NC} %-8s %s\n" "${name}" "${state}" "${ready}" "${msg}"
  done
}

# --- Main ---
DRY_RUN=false
DELETE_MODE=false
STATUS_MODE=false
SINGLE_BUNDLE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=true; shift ;;
    --delete)     DELETE_MODE=true; shift ;;
    --status)     STATUS_MODE=true; shift ;;
    --bundle)     SINGLE_BUNDLE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--delete] [--status] [--bundle <group>]"
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

load_config

echo -e "${BOLD}${BLUE}============================================================${NC}"
echo -e "${BOLD}${BLUE}  Fleet GitOps — Bundle Deployment${NC}"
echo -e "${BOLD}${BLUE}============================================================${NC}"
echo ""

if [[ "${STATUS_MODE}" == true ]]; then
  show_status
  exit 0
fi

if [[ "${DELETE_MODE}" == true ]]; then
  delete_bundles
  exit 0
fi

# Deploy bundles
deployed=0
failed=0

for entry in "${BUNDLE_DEFS[@]}"; do
  IFS='|' read -r name fleet_dir depends_on <<< "${entry}"

  # Filter by bundle group if specified
  if [[ -n "${SINGLE_BUNDLE}" ]]; then
    group="${fleet_dir%%/*}"
    if [[ "${group}" != "${SINGLE_BUNDLE}" ]]; then
      continue
    fi
  fi

  if create_bundle "${name}" "${fleet_dir}" "${depends_on}"; then
    deployed=$((deployed + 1))
  else
    failed=$((failed + 1))
    # Don't continue deploying if a bundle fails — dependencies will break
    die "Stopping deployment due to failure on ${name}"
  fi
done

echo ""
echo -e "${BOLD}Deployment summary:${NC}"
echo -e "  ${GREEN}Created/Updated:${NC} ${deployed}"
[[ ${failed} -gt 0 ]] && echo -e "  ${RED}Failed:${NC} ${failed}"
echo ""

if [[ "${DRY_RUN}" != true ]]; then
  log_info "Bundles created. Fleet will now deploy them to rke2-prod."
  log_info "Monitor with: $0 --status"
  log_info "Or via Rancher UI: ${RANCHER_URL}/dashboard/c/local/fleet/fleet.cattle.io.bundle"
fi
