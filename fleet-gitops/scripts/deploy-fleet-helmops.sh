#!/usr/bin/env bash
set -euo pipefail

# deploy-fleet-helmops.sh — Create Fleet HelmOp CRs on Rancher management cluster
#
# Uses Fleet HelmOps (not raw Bundle CRs) so deployments appear as App Bundles
# in the Rancher Fleet dashboard. All charts are sourced from Harbor OCI.
#
# Usage:
#   ./deploy-fleet-helmops.sh                        # Deploy all HelmOps
#   ./deploy-fleet-helmops.sh --group 00-operators   # Deploy single group
#   ./deploy-fleet-helmops.sh --dry-run              # Show CRs without applying
#   ./deploy-fleet-helmops.sh --delete               # Remove all HelmOps
#   ./deploy-fleet-helmops.sh --status               # Show deployment status
#
# Prerequisites:
#   - Helm charts pushed to oci://<HARBOR_HOST>/helm/ (push-charts.sh)
#   - Raw manifest bundles pushed to oci://<HARBOR_HOST>/fleet/ (push-bundles.sh)
#   - Root CA PEM at ./root-ca.pem (for cluster-autoscaler CA bundle)

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_DIR="$(dirname "${SCRIPT_DIR}")"

# Source .env early so BUNDLE_VERSION is available for HELMOP_DEFS array
if [[ -f "${FLEET_DIR}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${FLEET_DIR}/.env"
  set +a
fi
source "${SCRIPT_DIR}/lib/env-defaults.sh"

HARBOR="${HARBOR_HOST:?Set HARBOR_HOST in .env}"
BUNDLE_VERSION="${BUNDLE_VERSION:-1.0.0}"
RENDERED_DIR="${FLEET_DIR}/rendered"

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
    # Source .env (only exports lines matching KEY=VALUE)
    set -a
    # shellcheck source=/dev/null
    source "${env_file}"
    set +a
  fi

  [[ -n "${RANCHER_URL:-}" ]] || die "RANCHER_URL not set — run ./scripts/prepare.sh first"
  [[ -n "${RANCHER_TOKEN:-}" ]] || die "RANCHER_TOKEN not set — run ./scripts/prepare.sh first"

  # Validate token is still active
  local http_code
  http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${RANCHER_TOKEN}" \
    "${RANCHER_URL}/v3" 2>/dev/null)
  if [[ "${http_code}" != "200" ]]; then
    die "Rancher token expired or invalid (HTTP ${http_code}) — run ./scripts/prepare.sh --token-only to refresh"
  fi
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

# ============================================================
# HelmOp Definitions
# ============================================================
# Format: name|oci_repo|chart_or_empty|version|namespace|release_name|depends_on|values_file
#
# For upstream Helm charts: oci_repo=oci://harbor.../helm, chart=<name>
# For raw manifest bundles: oci_repo=oci://harbor.../fleet/<name>, chart=""
#
# HelmOp with OCI: when repo is oci://, chart MUST be empty (Fleet requirement)

HELMOP_DEFS=(
  # Format: name|oci_repo (full path, no separate chart for OCI)|version|namespace|release_name|depends_on|values_file
  #
  # For OCI: repo = oci://harbor/project/chart-name, chart field MUST be empty

  # 00-operators (prometheus-operator-crds first so ServiceMonitor/PrometheusRule CRDs are available)
  "operators-prometheus-crds|${OCI_CHART_PROMETHEUS_CRDS}|${CHART_VER_PROMETHEUS_CRDS}|monitoring|prometheus-operator-crds||"
  "operators-cnpg|${OCI_CHART_CNPG}|${CHART_VER_CNPG}|cnpg-system|cnpg||00-operators/cnpg-operator/values.yaml"
  "operators-redis|${OCI_CHART_REDIS_OPERATOR}|${CHART_VER_REDIS_OPERATOR}|redis-operator|redis-operator||00-operators/redis-operator/values.yaml"
  "operators-node-labeler|oci://${HARBOR}/fleet/operators-node-labeler|${BUNDLE_VERSION}|node-labeler|operators-node-labeler|operators-prometheus-crds|"
  "operators-storage-autoscaler|oci://${HARBOR}/fleet/operators-storage-autoscaler|${BUNDLE_VERSION}|storage-autoscaler|operators-storage-autoscaler|operators-prometheus-crds|"
  "operators-cluster-autoscaler|oci://${HARBOR}/fleet/operators-cluster-autoscaler|${BUNDLE_VERSION}|cluster-autoscaler|operators-cluster-autoscaler|operators-prometheus-crds|"
  "operators-overprovisioning|oci://${HARBOR}/fleet/operators-overprovisioning|${BUNDLE_VERSION}|cluster-autoscaler|operators-overprovisioning|operators-cluster-autoscaler|"
  "operators-gateway-api-crds|oci://${HARBOR}/fleet/operators-gateway-api-crds|${BUNDLE_VERSION}|kube-system|operators-gateway-api-crds||"

  # 05-pki-secrets (depends on operators)
  "pki-cert-manager|${OCI_CHART_CERT_MANAGER}|${CHART_VER_CERT_MANAGER}|cert-manager|cert-manager|operators-cnpg|05-pki-secrets/cert-manager/values.yaml"
  "pki-vault|${OCI_CHART_VAULT}|${CHART_VER_VAULT}|vault|vault|operators-cnpg|05-pki-secrets/vault/values.yaml"
  "pki-vault-init|oci://${HARBOR}/fleet/pki-vault-init|${BUNDLE_VERSION}|vault|pki-vault-init|pki-vault|"
  "pki-vault-unsealer|oci://${HARBOR}/fleet/pki-vault-unsealer|${BUNDLE_VERSION}|vault|pki-vault-unsealer|pki-vault-init|"
  "pki-vault-init-wait|oci://${HARBOR}/fleet/pki-vault-init-wait|${BUNDLE_VERSION}|vault|pki-vault-init-wait|pki-vault-init|"
  "pki-vault-pki-issuer|oci://${HARBOR}/fleet/pki-vault-pki-issuer|${BUNDLE_VERSION}|cert-manager|pki-vault-pki-issuer|pki-vault-init,pki-cert-manager|"
  "pki-external-secrets|${OCI_CHART_EXTERNAL_SECRETS}|${CHART_VER_EXTERNAL_SECRETS}|external-secrets|external-secrets|pki-vault-init-wait,operators-prometheus-crds|05-pki-secrets/external-secrets/values.yaml"
  "pki-vault-bootstrap-store|oci://${HARBOR}/fleet/pki-vault-bootstrap-store|${BUNDLE_VERSION}|external-secrets|pki-vault-bootstrap-store|pki-external-secrets|"

  # 10-identity (3 self-contained bundles, no shared init-lib.sh)
  "identity-cnpg-keycloak|oci://${HARBOR}/fleet/identity-cnpg-keycloak|${BUNDLE_VERSION}|database|identity-cnpg-keycloak|pki-vault-bootstrap-store,operators-cnpg|"
  "identity-keycloak-init|oci://${HARBOR}/fleet/identity-keycloak-init|${BUNDLE_VERSION}|keycloak|identity-keycloak-init|identity-cnpg-keycloak,pki-vault-bootstrap-store|"
  "identity-keycloak|${OCI_CHART_KEYCLOAKX}|${CHART_VER_KEYCLOAKX}|keycloak|identity-keycloak|identity-keycloak-init,identity-cnpg-keycloak,operators-prometheus-crds|10-identity/keycloak/values.yaml"
  "identity-keycloak-config|oci://${HARBOR}/fleet/identity-keycloak-config|${BUNDLE_VERSION}|keycloak|identity-keycloak-config|identity-keycloak|"

  # 15-dns (depends on pki — FreeIPA must be running externally)
  # NOT YET: external-dns requires FreeIPA to be running
  #"dns-external-dns-secrets|oci://${HARBOR}/fleet/dns-external-dns-secrets|${BUNDLE_VERSION}|external-dns|dns-external-dns-secrets|pki-external-secrets|"
  #"dns-external-dns|oci://${HARBOR}/helm/external-dns|1.16.1|external-dns|external-dns|dns-external-dns-secrets|15-dns/external-dns/values.yaml"

  # 11-infra-auth (depends on identity — Traefik/Vault/Hubble oauth2-proxy)
  "infra-auth-traefik|oci://${HARBOR}/fleet/infra-auth-traefik|${BUNDLE_VERSION}|kube-system|infra-auth-traefik|identity-keycloak-config|"
  "infra-auth-vault|oci://${HARBOR}/fleet/infra-auth-vault|${BUNDLE_VERSION}|vault|infra-auth-vault|identity-keycloak-config|"
  "infra-auth-hubble|oci://${HARBOR}/fleet/infra-auth-hubble|${BUNDLE_VERSION}|monitoring|infra-auth-hubble|identity-keycloak-config|"

  # 20-monitoring (depends on pki + identity — single consolidated init Job)
  "monitoring-init|oci://${HARBOR}/fleet/monitoring-init|${BUNDLE_VERSION}|monitoring|monitoring-init|identity-keycloak-config,pki-vault-bootstrap-store|"
  "monitoring-cnpg-grafana|oci://${HARBOR}/fleet/monitoring-cnpg-grafana|${BUNDLE_VERSION}|database|monitoring-cnpg-grafana|monitoring-init,operators-cnpg|"
  "monitoring-secrets|oci://${HARBOR}/fleet/monitoring-secrets|${BUNDLE_VERSION}|monitoring|monitoring-secrets|monitoring-init|"
  "monitoring-loki|oci://${HARBOR}/fleet/monitoring-loki|${BUNDLE_VERSION}|monitoring|monitoring-loki|monitoring-init|"
  "monitoring-alloy|oci://${HARBOR}/fleet/monitoring-alloy|${BUNDLE_VERSION}|monitoring|monitoring-alloy|monitoring-init|"
  "monitoring-prometheus-stack|${OCI_CHART_PROMETHEUS_STACK}|${CHART_VER_PROMETHEUS_STACK}|monitoring|kube-prometheus-stack|monitoring-secrets,monitoring-cnpg-grafana|20-monitoring/kube-prometheus-stack/values.yaml"
  "monitoring-ingress-auth|oci://${HARBOR}/fleet/monitoring-ingress-auth|${BUNDLE_VERSION}|monitoring|monitoring-ingress-auth|monitoring-prometheus-stack|"

  # 30-harbor (depends on pki + identity — waits for full identity stack)
  # minio bundle includes init Job that creates bootstrap admin, stores creds at admin/minio
  "minio|oci://${HARBOR}/fleet/minio|${BUNDLE_VERSION}|minio|minio|pki-vault-bootstrap-store|"
  "harbor-init|oci://${HARBOR}/fleet/harbor-init|${BUNDLE_VERSION}|harbor|harbor-init|minio,identity-keycloak-config,pki-vault-bootstrap-store|"
  "harbor-secrets|oci://${HARBOR}/fleet/harbor-secrets|${BUNDLE_VERSION}|harbor|harbor-secrets|harbor-init|"
  "harbor-cnpg|oci://${HARBOR}/fleet/harbor-cnpg-harbor|${BUNDLE_VERSION}|database|harbor-cnpg|harbor-init,operators-cnpg|"
  "harbor-valkey|oci://${HARBOR}/fleet/harbor-valkey|${BUNDLE_VERSION}|harbor|harbor-valkey|harbor-init,operators-redis|"
  "harbor-core|${OCI_CHART_HARBOR}|${CHART_VER_HARBOR}|harbor|harbor|minio,harbor-cnpg,harbor-valkey,harbor-secrets|30-harbor/harbor/values.yaml"
  "harbor-manifests|oci://${HARBOR}/fleet/harbor-manifests|${BUNDLE_VERSION}|harbor|harbor-manifests|harbor-core|"

  # 40-gitops (depends on pki + identity — waits for full identity stack)
  "gitops-argocd-init|oci://${HARBOR}/fleet/gitops-argocd-init|${BUNDLE_VERSION}|argocd|gitops-argocd-init|identity-keycloak-config,pki-vault-bootstrap-store|"
  "gitops-rollouts-init|oci://${HARBOR}/fleet/gitops-rollouts-init|${BUNDLE_VERSION}|argo-rollouts|gitops-rollouts-init|identity-keycloak-config,pki-vault-bootstrap-store|"
  "gitops-workflows-init|oci://${HARBOR}/fleet/gitops-workflows-init|${BUNDLE_VERSION}|argo-workflows|gitops-workflows-init|identity-keycloak-config,pki-vault-bootstrap-store|"
  "argocd-credentials|oci://${HARBOR}/fleet/gitops-argocd-credentials|${BUNDLE_VERSION}|argocd|gitops-argocd-credentials|gitops-argocd-init|"
  "gitops-argocd|${OCI_CHART_ARGOCD}|${CHART_VER_ARGOCD}|argocd|argocd|gitops-argocd-init,argocd-credentials|40-gitops/argocd/values.yaml"
  "gitops-argocd-manifests|oci://${HARBOR}/fleet/gitops-argocd-manifests|${BUNDLE_VERSION}|argocd|gitops-argocd-manifests|gitops-argocd|"
  "gitops-argocd-gitlab-setup|oci://${HARBOR}/fleet/gitops-argocd-gitlab-setup|${BUNDLE_VERSION}|argocd|gitops-argocd-gitlab-setup|gitops-argocd,gitlab-ready|"
  "gitops-argo-rollouts|${OCI_CHART_ARGO_ROLLOUTS}|${CHART_VER_ARGO_ROLLOUTS}|argo-rollouts|argo-rollouts|gitops-rollouts-init|40-gitops/argo-rollouts/values.yaml"
  "gitops-argo-rollouts-manifests|oci://${HARBOR}/fleet/gitops-argo-rollouts-manifests|${BUNDLE_VERSION}|argo-rollouts|gitops-argo-rollouts-manifests|gitops-argo-rollouts|"
  "gitops-argo-workflows|${OCI_CHART_ARGO_WORKFLOWS}|${CHART_VER_ARGO_WORKFLOWS}|argo-workflows|argo-workflows|gitops-workflows-init|40-gitops/argo-workflows/values.yaml"
  "gitops-argo-workflows-manifests|oci://${HARBOR}/fleet/gitops-argo-workflows-manifests|${BUNDLE_VERSION}|argo-workflows|gitops-argo-workflows-manifests|gitops-argo-workflows|"
  "gitops-analysis-templates|oci://${HARBOR}/fleet/gitops-analysis-templates|${BUNDLE_VERSION}|argo-rollouts|gitops-analysis-templates|gitops-rollouts-init|"

  # 50-gitlab (depends on pki + identity + harbor — waits for harbor-core)
  "gitlab-init|oci://${HARBOR}/fleet/gitlab-init|${BUNDLE_VERSION}|gitlab|gitlab-init|minio,identity-keycloak-config,pki-vault-bootstrap-store|"
  "gitlab-cnpg|oci://${HARBOR}/fleet/gitlab-cnpg-gitlab|${BUNDLE_VERSION}|database|gitlab-cnpg|gitlab-init,operators-cnpg|"
  "gitlab-redis|oci://${HARBOR}/fleet/gitlab-redis|${BUNDLE_VERSION}|gitlab|gitlab-redis|gitlab-init,operators-redis|"
  "gitlab-credentials|oci://${HARBOR}/fleet/gitlab-credentials|${BUNDLE_VERSION}|gitlab|gitlab-credentials|gitlab-init|"
  "gitlab-core|${OCI_CHART_GITLAB}|${CHART_VER_GITLAB}|gitlab|gitlab|gitlab-cnpg,gitlab-redis,gitlab-credentials,harbor-core|50-gitlab/gitlab-core/values.yaml"
  "gitlab-ready|oci://${HARBOR}/fleet/gitlab-ready|${BUNDLE_VERSION}|gitlab|gitlab-ready|gitlab-core|"
  "gitlab-manifests|oci://${HARBOR}/fleet/gitlab-manifests|${BUNDLE_VERSION}|gitlab|gitlab-manifests|gitlab-ready,gitlab-init,operators-gateway-api-crds|"
  "gitlab-runners|oci://${HARBOR}/fleet/gitlab-runners|${BUNDLE_VERSION}|gitlab-runners|gitlab-runners|gitlab-ready|"
  "gitlab-runner-shared|${OCI_CHART_GITLAB_RUNNER}|${CHART_VER_GITLAB_RUNNER}|gitlab-runners|gitlab-runner-shared|gitlab-runners|50-gitlab/gitlab-runner-shared/values.yaml"
  "gitlab-runner-terraform|${OCI_CHART_GITLAB_RUNNER}|${CHART_VER_GITLAB_RUNNER}|gitlab-runners|gitlab-runner-terraform|gitlab-runners|50-gitlab/gitlab-runner-terraform/values.yaml"
)

# ============================================================
# Build HelmOp CR JSON
# ============================================================
build_helmop_cr() {
  local name="$1"
  local oci_repo="$2"
  local version="$3"
  local namespace="$4"
  local release_name="$5"
  local depends_on="$6"
  local values_file_rel="$7"

  # Build dependsOn array
  local deps_json="[]"
  if [[ -n "${depends_on}" ]]; then
    deps_json=$(echo "${depends_on}" | tr ',' '\n' | jq -Rn '
      [inputs | select(length > 0) | {name: .}]
    ')
  fi

  # Build values JSON from values file if provided
  local values_json="{}"
  if [[ -n "${values_file_rel}" ]]; then
    local values_path="${RENDERED_DIR}/${values_file_rel}"
    if [[ -f "${values_path}" ]]; then
      values_json=$(python3 -c "
import yaml, json
with open('${values_path}') as f:
    d = yaml.safe_load(f)
print(json.dumps(d if d else {}))
")
    else
      log_warn "Values file not found: ${values_path}"
    fi
  fi

  # --- Inject secrets from downstream cluster into values at deploy time ---
  # Harbor chart uses lookup() for existingSecret which is incompatible with
  # Fleet's remote Helm rendering. Fetch the password from the downstream
  # cluster's K8s secret and inject it as a literal value.
  if [[ "${name}" == "harbor-core" ]]; then
    local valkey_pw=""
    local cluster_id
    cluster_id=$(rancher_api GET "/v3/clusters" 2>/dev/null | \
      python3 -c "import json,sys; [print(c['id']) for c in json.load(sys.stdin).get('data',[]) if c.get('name')=='${FLEET_TARGET_CLUSTER}']" 2>/dev/null || true)
    if [[ -n "${cluster_id}" ]]; then
      local ds_kc
      ds_kc=$(mktemp /tmp/ds-kubeconfig.XXXXXX)
      rancher_api POST "/v3/clusters/${cluster_id}?action=generateKubeconfig" 2>/dev/null | \
        python3 -c "import json,sys; print(json.load(sys.stdin)['config'])" > "${ds_kc}" 2>/dev/null || true
      if [[ -s "${ds_kc}" ]]; then
        valkey_pw=$(kubectl --kubeconfig="${ds_kc}" get secret harbor-valkey-credentials -n harbor \
          -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
      fi
      rm -f "${ds_kc}"
    fi
    if [[ -n "${valkey_pw}" ]]; then
      values_json=$(echo "${values_json}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
d.setdefault('redis', {}).setdefault('external', {})['password'] = sys.argv[1]
print(json.dumps(d))
" "${valkey_pw}")
      echo "[INFO] Injected Valkey password into harbor-core values" >&2
    else
      echo "[WARN] harbor-valkey-credentials not found — harbor-core will use placeholder Redis password (re-run after Valkey is ready)" >&2
    fi
  fi

  local values_file_tmp
  values_file_tmp=$(mktemp /tmp/fleet-helmop-values-XXXXXX.json)
  echo "${values_json}" > "${values_file_tmp}"

  # Build the HelmOp CR
  # All OCI: repo contains full OCI URL, chart must be empty
  local helmop_json
  helmop_json=$(jq -n \
    --arg name "${name}" \
    --arg repo "${oci_repo}" \
    --arg version "${version}" \
    --arg namespace "${namespace}" \
    --arg release "${release_name}" \
    --argjson deps "${deps_json}" \
    --arg fleet_ns "${FLEET_NAMESPACE}" \
    --arg target_cluster "${FLEET_TARGET_CLUSTER}" \
    --slurpfile values "${values_file_tmp}" \
    '{
      apiVersion: "fleet.cattle.io/v1alpha1",
      kind: "HelmOp",
      metadata: {
        name: $name,
        namespace: $fleet_ns
      },
      spec: {
        helm: {
          repo: $repo,
          version: $version,
          releaseName: $release,
          values: $values[0],
          takeOwnership: true,
          waitForJobs: true
        },
        correctDrift: {
          enabled: false
        },
        diff: {
          comparePatches: [
            {
              apiVersion: "apps/v1",
              kind: "Deployment",
              jsonPointers: ["/spec/replicas"]
            },
            {
              apiVersion: "apps/v1",
              kind: "StatefulSet",
              jsonPointers: ["/spec/replicas"]
            }
          ]
        },
        helmSecretName: "harbor-helm-ca",
        dependsOn: $deps,
        defaultNamespace: $namespace,
        targets: [{clusterName: $target_cluster}]
      }
    }')

  rm -f "${values_file_tmp}"
  echo "${helmop_json}"
}

# ============================================================
# Create a HelmOp CR via Rancher API
# ============================================================
create_helmop() {
  local name="$1" oci_repo="$2" version="$3"
  local namespace="$4" release="$5" depends="$6" values_file="$7"

  log_info "Creating HelmOp: ${name}..."

  local tmpfile
  tmpfile=$(mktemp /tmp/fleet-helmop-XXXXXX.json)
  trap 'rm -f "${tmpfile:-}"' RETURN

  build_helmop_cr "${name}" "${oci_repo}" "${version}" \
    "${namespace}" "${release}" "${depends}" "${values_file}" > "${tmpfile}"

  if [[ "${DRY_RUN}" == true ]]; then
    jq '.' "${tmpfile}"
    log_ok "Dry run: ${name}"
    return 0
  fi

  # Check if it already exists
  local existing
  existing=$(rancher_api GET "/v1/fleet.cattle.io.helmops/fleet-default/${name}" 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('metadata',{}).get('name',''))" 2>/dev/null || echo "")

  if [[ "${existing}" == "${name}" ]]; then
    log_warn "HelmOp ${name} already exists — updating"
    local rv
    rv=$(rancher_api GET "/v1/fleet.cattle.io.helmops/fleet-default/${name}" | \
      python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['resourceVersion'])")
    jq --arg rv "${rv}" '.metadata.resourceVersion = $rv' "${tmpfile}" > "${tmpfile}.tmp" && mv "${tmpfile}.tmp" "${tmpfile}"
    local resp
    resp=$(rancher_api PUT "/v1/fleet.cattle.io.helmops/fleet-default/${name}" -d "@${tmpfile}")
    local err
    err=$(echo "${resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message',''))" 2>/dev/null || echo "")
    if [[ -n "${err}" ]]; then
      log_error "Failed to update ${name}: ${err}"
      return 1
    fi
    log_ok "Updated: ${name}"
  else
    local resp
    resp=$(rancher_api POST "/v1/fleet.cattle.io.helmops" -d "@${tmpfile}")
    local created
    created=$(echo "${resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('metadata',{}).get('name',''))" 2>/dev/null || echo "")
    if [[ "${created}" != "${name}" ]]; then
      local err
      err=$(echo "${resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('message', d.get('reason','unknown')))" 2>/dev/null || echo "unknown")
      log_error "Failed to create ${name}: ${err}"
      echo "${resp}" | jq '.' 2>/dev/null || echo "${resp}"
      return 1
    fi
    log_ok "Created: ${name}"
  fi
}

# ============================================================
# Delete all HelmOps
# ============================================================
delete_helmops() {
  log_info "Deleting all Fleet HelmOps..."
  for entry in "${HELMOP_DEFS[@]}"; do
    IFS='|' read -r name _ _ _ _ _ _ <<< "${entry}"
    local existing
    existing=$(rancher_api GET "/v1/fleet.cattle.io.helmops/fleet-default/${name}" 2>/dev/null | \
      python3 -c "import sys,json; print(json.load(sys.stdin).get('metadata',{}).get('name',''))" 2>/dev/null || echo "")
    if [[ "${existing}" == "${name}" ]]; then
      rancher_api DELETE "/v1/fleet.cattle.io.helmops/fleet-default/${name}" > /dev/null 2>&1
      log_ok "Deleted: ${name}"
    fi
  done

  # Also clean up any leftover Bundle CRs from old approach
  log_info "Cleaning up old Bundle CRs..."
  local bundles
  bundles=$(rancher_api GET "/v1/fleet.cattle.io.bundles?namespace=fleet-default" 2>/dev/null | \
    python3 -c "
import sys,json
d=json.load(sys.stdin)
for i in d.get('data',[]):
    name=i['metadata']['name']
    if not name.startswith('fleet-agent'):
        print(name)
" 2>/dev/null || true)

  while IFS= read -r bname; do
    [[ -z "${bname}" ]] && continue
    rancher_api DELETE "/v1/fleet.cattle.io.bundles/fleet-default/${bname}" > /dev/null 2>&1
    log_ok "Deleted old bundle: ${bname}"
  done <<< "${bundles}"

  # --- Clean up downstream cluster resources ---
  log_info "Cleaning up downstream cluster resources..."

  # Get downstream cluster kubeconfig
  local cluster_id
  cluster_id=$(rancher_api GET "/v3/clusters" 2>/dev/null | \
    python3 -c "import json,sys; [print(c['id']) for c in json.load(sys.stdin).get('data',[]) if c.get('name')=='${FLEET_TARGET_CLUSTER}']" 2>/dev/null || true)

  if [[ -z "${cluster_id}" ]]; then
    log_warn "Could not find ${FLEET_TARGET_CLUSTER} cluster — skipping downstream cleanup"
    return 0
  fi

  local ds_kc
  ds_kc=$(mktemp /tmp/ds-kubeconfig-cleanup.XXXXXX)
  rancher_api POST "/v3/clusters/${cluster_id}?action=generateKubeconfig" 2>/dev/null | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['config'])" > "${ds_kc}" 2>/dev/null || true

  if [[ ! -s "${ds_kc}" ]]; then
    log_warn "Could not generate downstream kubeconfig — skipping downstream cleanup"
    rm -f "${ds_kc}"
    return 0
  fi

  # Collect unique namespaces from HELMOP_DEFS (excluding kube-system)
  local -A helmop_namespaces
  for entry in "${HELMOP_DEFS[@]}"; do
    IFS='|' read -r _ _ _ ns _ _ _ <<< "${entry}"
    [[ "${ns}" == "kube-system" ]] && continue
    helmop_namespaces["${ns}"]=1
  done

  # Uninstall any leftover Helm releases in those namespaces
  log_info "Removing leftover Helm releases on downstream cluster..."
  for ns in "${!helmop_namespaces[@]}"; do
    local releases
    releases=$(helm --kubeconfig="${ds_kc}" list -n "${ns}" --no-headers -q 2>/dev/null || true)
    while IFS= read -r rel; do
      [[ -z "${rel}" ]] && continue
      log_info "Uninstalling Helm release: ${rel} (ns: ${ns})"
      helm --kubeconfig="${ds_kc}" uninstall "${rel}" -n "${ns}" --wait --timeout 120s 2>&1 || \
        log_warn "Failed to uninstall ${rel} in ${ns} — may need manual cleanup"
      log_ok "Uninstalled: ${rel}"
    done <<< "${releases}"
  done

  # Delete CRDs that were installed by Fleet bundles.
  # Use dynamic discovery by API group to catch all CRDs (including generators,
  # ArgoCD, etc.) rather than maintaining a static list.
  log_info "Removing Fleet-deployed CRDs..."
  local fleet_crd_groups=(
    "cnpg.io"
    "external-secrets.io"
    "generators.external-secrets.io"
    "cert-manager.io"
    "acme.cert-manager.io"
    "monitoring.coreos.com"
    "argoproj.io"
    "redis.opstreelabs.in"
    "redis.redis.opstreelabs.in"
  )
  for group in "${fleet_crd_groups[@]}"; do
    while IFS= read -r crd; do
      [[ -n "${crd}" ]] || continue
      kubectl --kubeconfig="${ds_kc}" delete crd "${crd}" --timeout=30s 2>/dev/null && \
        log_ok "Deleted CRD: ${crd}" || \
        log_warn "Failed to delete CRD ${crd}"
    done < <(kubectl --kubeconfig="${ds_kc}" get crd 2>/dev/null | grep "${group}" | awk '{print $1}')
  done

  # Strip operator CRD finalizers before deleting namespaces.
  # Operator-managed CRs (RedisReplication, RedisSentinel, etc.) have custom
  # finalizers that require the operator pod to process. If the operator
  # namespace is deleted first, these finalizers block namespace deletion.
  log_info "Stripping operator CR finalizers..."
  local cr_types=("redisreplications.redis.redis.opstreelabs.in" "redissentinels.redis.redis.opstreelabs.in")
  for cr_type in "${cr_types[@]}"; do
    while IFS='/' read -r cr_ns cr_name; do
      [[ -n "${cr_name}" ]] || continue
      kubectl --kubeconfig="${ds_kc}" patch "${cr_type}" "${cr_name}" -n "${cr_ns}" \
        --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null && \
        log_ok "Stripped finalizer: ${cr_type}/${cr_name} in ${cr_ns}" || true
    done < <(kubectl --kubeconfig="${ds_kc}" get "${cr_type}" -A --no-headers \
      -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' 2>/dev/null | \
      awk '{print $1"/"$2}')
  done

  # Strip ExternalSecret finalizers — ESO controller is already removed,
  # so these finalizers will never be processed and block namespace deletion.
  log_info "Stripping ExternalSecret finalizers..."
  while IFS='/' read -r es_ns es_name; do
    [[ -n "${es_name}" ]] || continue
    kubectl --kubeconfig="${ds_kc}" patch externalsecret "${es_name}" -n "${es_ns}" \
      --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null && \
      log_ok "Stripped ExternalSecret finalizer: ${es_name} in ${es_ns}" || true
  done < <(kubectl --kubeconfig="${ds_kc}" get externalsecrets.external-secrets.io -A --no-headers \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' 2>/dev/null | \
    awk '{print $1"/"$2}')

  # Force-delete completed/failed pods that block namespace deletion.
  # StatefulSet pods in Completed state (e.g., from node scale-downs) prevent
  # the namespace finalizer from completing.
  log_info "Force-deleting stuck pods..."
  for ns in "${!helmop_namespaces[@]}"; do
    while IFS= read -r pod_name; do
      [[ -n "${pod_name}" ]] || continue
      kubectl --kubeconfig="${ds_kc}" delete pod "${pod_name}" -n "${ns}" \
        --force --grace-period=0 2>/dev/null && \
        log_ok "Force-deleted pod: ${pod_name} in ${ns}" || true
    done < <(kubectl --kubeconfig="${ds_kc}" get pods -n "${ns}" --no-headers \
      --field-selector='status.phase!=Running' -o custom-columns='NAME:.metadata.name' 2>/dev/null)
  done

  # Delete namespaces (this removes all remaining resources inside them)
  log_info "Removing Fleet-managed namespaces..."
  for ns in "${!helmop_namespaces[@]}"; do
    if kubectl --kubeconfig="${ds_kc}" get ns "${ns}" &>/dev/null; then
      log_info "Deleting namespace: ${ns}"
      kubectl --kubeconfig="${ds_kc}" delete ns "${ns}" --timeout=120s 2>&1 || \
        log_warn "Namespace ${ns} deletion timed out — may have finalizers"
      log_ok "Deleted namespace: ${ns}"
    fi
  done

  rm -f "${ds_kc}"
  log_ok "Downstream cluster cleanup complete"
}

# ============================================================
# Purge OCI artifacts from Harbor
# ============================================================
purge_harbor_oci() {
  local harbor_user="${HARBOR_USER:?Set HARBOR_USER in .env}"
  local harbor_pass="${HARBOR_PASS:?Set HARBOR_PASS in .env}"

  log_info "Purging OCI artifacts from Harbor..."

  # Delete raw-manifest bundle repos from fleet/ project
  local bundle_names=(
    operators-cluster-autoscaler operators-overprovisioning operators-node-labeler operators-storage-autoscaler operators-gateway-api-crds
    pki-vault-init pki-vault-init-wait pki-vault-unsealer pki-vault-pki-issuer pki-vault-bootstrap-store
    identity-cnpg-keycloak identity-keycloak-init identity-keycloak identity-keycloak-config
    infra-auth-traefik infra-auth-vault infra-auth-hubble
    dns-external-dns-secrets
    monitoring-init monitoring-cnpg-grafana monitoring-secrets monitoring-loki monitoring-alloy monitoring-ingress-auth
    harbor-init harbor-secrets minio harbor-cnpg-harbor harbor-valkey harbor-manifests
    gitops-argocd-init gitops-rollouts-init gitops-workflows-init gitops-argocd-credentials gitops-argocd-manifests gitops-argocd-gitlab-setup gitops-argo-rollouts-manifests gitops-argo-workflows-manifests gitops-analysis-templates
    gitlab-init gitlab-cnpg-gitlab gitlab-redis gitlab-credentials gitlab-ready gitlab-manifests gitlab-runners
  )

  for repo in "${bundle_names[@]}"; do
    local code
    code=$(curl -sk -o /dev/null -w "%{http_code}" \
      -u "${harbor_user}:${harbor_pass}" \
      -X DELETE "https://${HARBOR}/api/v2.0/projects/fleet/repositories/${repo}")
    if [[ "${code}" == "200" ]]; then
      log_ok "Deleted Harbor repo: fleet/${repo}"
    elif [[ "${code}" == "404" ]]; then
      log_info "Not found (skip): fleet/${repo}"
    else
      log_warn "Failed to delete fleet/${repo} (HTTP ${code})"
    fi
  done

  # Delete upstream Helm chart repos from helm/ project
  local chart_names=(
    cloudnative-pg redis-operator cert-manager vault external-secrets
    kube-prometheus-stack harbor argo-cd argo-rollouts argo-workflows gitlab
  )

  for repo in "${chart_names[@]}"; do
    local code
    code=$(curl -sk -o /dev/null -w "%{http_code}" \
      -u "${harbor_user}:${harbor_pass}" \
      -X DELETE "https://${HARBOR}/api/v2.0/projects/helm/repositories/${repo}")
    if [[ "${code}" == "200" ]]; then
      log_ok "Deleted Harbor repo: helm/${repo}"
    elif [[ "${code}" == "404" ]]; then
      log_info "Not found (skip): helm/${repo}"
    else
      log_warn "Failed to delete helm/${repo} (HTTP ${code})"
    fi
  done

  log_ok "Harbor OCI purge complete"
}

# ============================================================
# Helper: recreate a HelmOp from a HELMOP_DEFS entry
# ============================================================
create_helmop_from_def() {
  local entry="$1"
  local name oci_repo version namespace release depends values_file
  IFS='|' read -r name oci_repo version namespace release depends values_file <<< "${entry}"
  create_helmop "${name}" "${oci_repo}" "${version}" \
    "${namespace}" "${release}" "${depends}" "${values_file}"
}

# ============================================================
# Self-heal stuck bundles (Modified with missing resources)
# ============================================================
# Fleet's Helm deployer sometimes marks bundles "Deployed: True" but
# doesn't actually create the resources on the downstream cluster.
# Deleting the generated Bundle CR forces Fleet to re-apply from the
# HelmOp, which resolves the issue.
heal_stuck_bundles() {
  local max_wait="${1:-300}"  # Default 5 min
  local poll_interval=15
  local elapsed=0
  local healed=0

  log_info "Waiting for bundle convergence (up to ${max_wait}s)..."

  while (( elapsed < max_wait )); do
    local stuck_bundles=()

    # NEVER self-heal stateful bundles — deleting the Bundle CR cascades
    # to downstream resources (CNPG clusters, Redis, Vault). Data loss.
    local -a HEAL_EXCLUSIONS=(
      identity-cnpg-keycloak
      monitoring-cnpg-grafana
      harbor-cnpg
      gitlab-cnpg
      gitlab-redis
      harbor-valkey
      pki-vault
    )

    for entry in "${HELMOP_DEFS[@]}"; do
      IFS='|' read -r name _ _ _ _ _ _ <<< "${entry}"

      # Skip stateful bundles — never auto-heal databases or data stores
      local skip=false
      for excl in "${HEAL_EXCLUSIONS[@]}"; do
        if [[ "${name}" == "${excl}" ]]; then
          skip=true
          break
        fi
      done
      if [[ "${skip}" == "true" ]]; then
        continue
      fi

      # Query bundle status
      local bundle_json
      bundle_json=$(rancher_api GET "/v1/fleet.cattle.io.bundles/fleet-default/${name}" 2>/dev/null || echo "{}")

      # Check for "Modified" state with "missing" resources
      local has_missing
      has_missing=$(echo "${bundle_json}" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    summary=d.get('status',{}).get('summary',{})
    modified=summary.get('modified',0)
    if modified == 0:
        sys.exit(0)
    for nr in summary.get('nonReadyResources',[]):
        for ms in nr.get('modifiedStatus',[]):
            if ms.get('missing'):
                print(nr.get('name',''))
                sys.exit(0)
except: pass
" 2>/dev/null || echo "")

      if [[ -n "${has_missing}" ]]; then
        stuck_bundles+=("${name}")
      fi
    done

    if (( ${#stuck_bundles[@]} == 0 )); then
      if (( healed > 0 )); then
        log_ok "All stuck bundles recovered (${healed} healed)"
      fi
      return 0
    fi

    if (( elapsed > 0 && elapsed % 60 == 0 )); then
      # After waiting, heal stuck bundles by deleting both HelmOp + Bundle,
      # then recreating the HelmOp. Fleet only regenerates Bundles when the
      # HelmOp is created/updated — deleting just the Bundle is not enough.
      for stuck_name in "${stuck_bundles[@]}"; do
        log_warn "Bundle ${stuck_name} stuck in Modified (missing resources) — force-recreating HelmOp"
        # Delete Bundle CR first (downstream resources will be cleaned up)
        rancher_api DELETE "/v1/fleet.cattle.io.bundles/fleet-default/${stuck_name}" > /dev/null 2>&1 || true
        # Delete the HelmOp so we can recreate it
        rancher_api DELETE "/v1/fleet.cattle.io.helmops/fleet-default/${stuck_name}" > /dev/null 2>&1 || true
        sleep 5
        # Find and recreate the HelmOp from HELMOP_DEFS
        for def_entry in "${HELMOP_DEFS[@]}"; do
          local def_name
          IFS='|' read -r def_name _ _ _ _ _ _ <<< "${def_entry}"
          if [[ "${def_name}" == "${stuck_name}" ]]; then
            create_helmop_from_def "${def_entry}" || log_warn "Failed to recreate HelmOp ${stuck_name}"
            break
          fi
        done
        (( ++healed ))
      done
      log_info "Recreated ${#stuck_bundles[@]} stuck HelmOps — waiting for Fleet to deploy"

      # Also reset Helm releases for bundles that depend on healed bundles.
      # These may have started before the healed bundle's resources existed,
      # causing Jobs to fail with stale auth/config. Deleting their Helm
      # releases forces Fleet to re-deploy them with correct ordering.
      local ds_kc_heal
      ds_kc_heal=$(mktemp /tmp/ds-kubeconfig-heal.XXXXXX)
      local _cluster_id
      _cluster_id=$(rancher_api GET "/v3/clusters" 2>/dev/null | \
        python3 -c "import sys,json; [print(c['id']) for c in json.load(sys.stdin).get('data',[]) if c['name']=='${FLEET_TARGET_CLUSTER}']" 2>/dev/null | head -1)
      rancher_api POST "/v3/clusters/${_cluster_id}?action=generateKubeconfig" 2>/dev/null | \
        python3 -c "import json,sys; print(json.load(sys.stdin)['config'])" > "${ds_kc_heal}" 2>/dev/null || true

      if [[ -s "${ds_kc_heal}" ]]; then
        for stuck_name in "${stuck_bundles[@]}"; do
          # Find bundles that depend on the healed bundle
          for def_entry in "${HELMOP_DEFS[@]}"; do
            local dep_name dep_depends
            IFS='|' read -r dep_name _ _ dep_ns _ dep_depends _ <<< "${def_entry}"
            if [[ "${dep_depends}" == *"${stuck_name}"* && "${dep_name}" != "${stuck_name}" ]]; then
              # Delete Helm releases for this dependent bundle on downstream cluster
              local release_name="${dep_name}"
              local deleted_releases
              deleted_releases=$(kubectl --kubeconfig="${ds_kc_heal}" delete secrets -n "${dep_ns}" \
                -l "name=${release_name},owner=helm" --ignore-not-found 2>&1 | grep -c "deleted" || echo "0")
              if (( deleted_releases > 0 )); then
                log_info "Reset downstream Helm release for dependent: ${dep_name} (depends on ${stuck_name})"
              fi
            fi
          done
        done
      fi
      rm -f "${ds_kc_heal}"
    else
      log_info "  ${#stuck_bundles[@]} bundle(s) not yet converged: ${stuck_bundles[*]} (${elapsed}s/${max_wait}s)"
    fi

    sleep "${poll_interval}"
    (( elapsed += poll_interval ))
  done

  # Final check
  local remaining=()
  for entry in "${HELMOP_DEFS[@]}"; do
    IFS='|' read -r name _ _ _ _ _ _ <<< "${entry}"
    local has_missing
    has_missing=$(rancher_api GET "/v1/fleet.cattle.io.bundles/fleet-default/${name}" 2>/dev/null | \
      python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for nr in d.get('status',{}).get('summary',{}).get('nonReadyResources',[]):
        for ms in nr.get('modifiedStatus',[]):
            if ms.get('missing'):
                print('stuck')
                sys.exit(0)
except: pass
" 2>/dev/null || echo "")
    [[ -n "${has_missing}" ]] && remaining+=("${name}")
  done

  if (( ${#remaining[@]} > 0 )); then
    log_warn "Bundles still stuck after ${max_wait}s: ${remaining[*]}"
    log_warn "These may require manual investigation"
    return 1
  fi

  log_ok "All bundles converged (${healed} healed)"
  return 0
}

# ============================================================
# Show status
# ============================================================
show_status() {
  local total=0 ready_count=0

  echo -e "${BOLD}Fleet HelmOp Status:${NC}  $(date '+%H:%M:%S')"
  printf "%-35s %-12s %-8s %s\n" "HELMOP" "STATE" "READY" "MESSAGE"
  printf "%-35s %-12s %-8s %s\n" "------" "-----" "-----" "-------"

  for entry in "${HELMOP_DEFS[@]}"; do
    IFS='|' read -r name _ _ _ _ _ _ <<< "${entry}"
    (( ++total ))

    # Check HelmOp status
    local helmop_state
    helmop_state=$(rancher_api GET "/v1/fleet.cattle.io.helmops/fleet-default/${name}" 2>/dev/null | \
      python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    state=d.get('metadata',{}).get('state',{}).get('name','unknown')
    msg=d.get('metadata',{}).get('state',{}).get('message','')[:60]
    print(f'{state}|{msg}')
except (json.JSONDecodeError, KeyError, TypeError):
    print('NotFound|')
" 2>/dev/null || echo "Error|")

    IFS='|' read -r state msg <<< "${helmop_state}"

    # Also check the generated bundle
    local bundle_info
    bundle_info=$(rancher_api GET "/v1/fleet.cattle.io.bundles/fleet-default/${name}" 2>/dev/null | \
      python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    summary=d.get('status',{}).get('summary',{})
    ready=summary.get('ready',0)
    desired=summary.get('desiredReady',0)
    print(f'{ready}/{desired}')
except (json.JSONDecodeError, KeyError, TypeError):
    print('-')
" 2>/dev/null || echo "-")

    local color="${RED}"
    if [[ "${state}" == "active" ]]; then
      color="${GREEN}"
      (( ++ready_count ))
    fi
    [[ "${state}" == "NotFound" ]] && color="${YELLOW}"

    printf "%-35s ${color}%-12s${NC} %-8s %s\n" "${name}" "${state}" "${bundle_info}" "${msg}"
  done

  echo ""
  if (( ready_count == total )); then
    echo -e "${GREEN}${BOLD}All ${total} bundles ready${NC}"
  else
    echo -e "${YELLOW}${ready_count}/${total} bundles ready${NC}"
  fi

  # Return 0 if all ready, 1 if not (used by watch_status loop)
  (( ready_count == total )) || return 1
}

watch_status() {
  local interval="${WATCH_INTERVAL:-10}"
  local prev_lines=0

  # Restore cursor on exit (Ctrl+C or normal)
  trap 'tput cnorm 2>/dev/null; exit' INT TERM EXIT
  tput civis 2>/dev/null  # hide cursor during updates

  while true; do
    # Move cursor up to overwrite previous output
    if (( prev_lines > 0 )); then
      printf '\033[%dA' "${prev_lines}"
    fi

    # Capture show_status output and exit code
    local output converged=false
    output=$(show_status) && converged=true || true

    # Print each line, clearing remainder to avoid leftover chars
    local line_count=0
    while IFS= read -r line; do
      printf '%s\033[K\n' "${line}"
      (( ++line_count ))
    done <<< "${output}"

    if [[ "${converged}" == true ]]; then
      printf '\033[K\n'
      echo -e "${GREEN}${BOLD}All bundles converged — exiting watch.${NC}"
      tput cnorm 2>/dev/null
      exit 0
    fi

    printf '\033[K'
    echo -e "${BLUE}Last refresh: $(date '+%H:%M:%S') — next in ${interval}s (Ctrl+C to stop)${NC}"
    (( ++line_count ))

    prev_lines="${line_count}"
    sleep "${interval}"
  done
}

# ============================================================
# Main
# ============================================================
DRY_RUN=false
DELETE_MODE=false
PURGE_MODE=false
STATUS_MODE=false
WATCH_MODE=false
WATCH_INTERVAL=10
SINGLE_GROUP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=true; shift ;;
    --delete)     DELETE_MODE=true; shift ;;
    --purge)      PURGE_MODE=true; shift ;;
    --status)     STATUS_MODE=true; shift ;;
    --watch)      WATCH_MODE=true; shift ;;
    --interval)   WATCH_INTERVAL="$2"; shift 2 ;;
    --group)      SINGLE_GROUP="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--delete] [--purge] [--status] [--watch] [--group <group>]"
      echo ""
      echo "  --delete     Remove all HelmOps from Fleet (keeps Harbor OCI artifacts)"
      echo "  --purge      Remove HelmOps from Fleet AND delete OCI artifacts from Harbor"
      echo "  --status     Show deployment status"
      echo "  --watch      Live-watch status until all bundles converge (implies --status)"
      echo "  --interval   Refresh interval in seconds for --watch (default: 10)"
      echo "  --group      Deploy/delete a single group (e.g., 50-gitlab)"
      echo "  --dry-run    Show CRs without applying"
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

load_config

# Render templates (substitutes env vars into YAML for values files)
log_info "Rendering templates..."
"${SCRIPT_DIR}/render-templates.sh"

# Re-inject spec-hash annotations (render-templates.sh overwrites them)
"${SCRIPT_DIR}/compute-job-hashes.sh" 2>/dev/null || true

echo -e "${BOLD}${BLUE}============================================================${NC}"
echo -e "${BOLD}${BLUE}  Fleet GitOps — HelmOp Deployment${NC}"
echo -e "${BOLD}${BLUE}============================================================${NC}"
echo ""

if [[ "${STATUS_MODE}" == true || "${WATCH_MODE}" == true ]]; then
  if [[ "${WATCH_MODE}" == true ]]; then
    watch_status
  else
    show_status || true
  fi
  exit 0
fi

if [[ "${DELETE_MODE}" == true ]]; then
  delete_helmops
  exit 0
fi

if [[ "${PURGE_MODE}" == true ]]; then
  delete_helmops
  purge_harbor_oci
  exit 0
fi

# --- Ensure harbor-helm-ca secret exists on management cluster ---
# Fleet HelmOps reference this secret to pull OCI charts from Harbor over TLS.
# The root CA is extracted from the Rancher downstream cluster's kubeconfig
# (the CA that signed Harbor's TLS certificate).
ensure_harbor_helm_ca() {
  local existing
  existing=$(rancher_api GET "/k8s/clusters/local/api/v1/namespaces/fleet-default/secrets/harbor-helm-ca" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('metadata',{}).get('name',''))" 2>/dev/null || echo "")
  if [[ "${existing}" == "harbor-helm-ca" ]]; then
    log_ok "harbor-helm-ca secret already exists"
    return 0
  fi

  log_info "Creating harbor-helm-ca secret on management cluster..."

  # Extract root CA from Harbor's TLS chain
  local ca_pem
  ca_pem=$(echo | openssl s_client -connect "${HARBOR}:443" -showcerts 2>/dev/null | \
    awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/{print}' | \
    awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++} n>=2{print}')

  if [[ -z "${ca_pem}" ]]; then
    # Fallback: try getting from Rancher cluster provisioning config
    ca_pem=$(rancher_api GET "/v3/clusters" 2>/dev/null | \
      python3 -c "
import sys,json,base64
data=json.load(sys.stdin)
for c in data.get('data',[]):
    if c.get('name') not in ('local',''):
        ca = c.get('caCert','')
        if ca:
            print(ca)
            break
" 2>/dev/null || echo "")
  fi

  if [[ -z "${ca_pem}" ]]; then
    log_warn "Could not extract root CA — harbor-helm-ca must be created manually"
    return 1
  fi

  local ca_b64
  ca_b64=$(echo "${ca_pem}" | base64 -w0)

  local harbor_user="${HARBOR_USER:?Set HARBOR_USER in .env}"
  local harbor_pass="${HARBOR_PASS:?Set HARBOR_PASS in .env}"

  rancher_api POST "/k8s/clusters/local/api/v1/namespaces/fleet-default/secrets" -d "$(jq -n \
    --arg ca "${ca_b64}" \
    --arg user "$(echo -n "${harbor_user}" | base64 -w0)" \
    --arg pass "$(echo -n "${harbor_pass}" | base64 -w0)" \
    '{
      apiVersion: "v1",
      kind: "Secret",
      metadata: {name: "harbor-helm-ca", namespace: "fleet-default"},
      type: "Opaque",
      data: {cacerts: $ca, username: $user, password: $pass}
    }')" > /dev/null 2>&1

  log_ok "Created harbor-helm-ca secret"
}

ensure_harbor_helm_ca

# --- Seed CI secrets into Vault on downstream cluster ---
# These secrets are read by ExternalSecrets in gitlab-runners and argo-workflows.
# Values come from .env; if not set, the seeding is skipped with a warning.
seed_ci_secrets() {
  log_info "Checking CI secrets in Vault..."

  # Get downstream cluster kubeconfig
  local cluster_id ds_kc
  cluster_id=$(rancher_api GET "/v3/clusters" | python3 -c "
import json,sys
[print(c['id']) for c in json.load(sys.stdin).get('data',[]) if c.get('name')=='${FLEET_TARGET_CLUSTER}']
" 2>/dev/null | head -1)
  [[ -n "${cluster_id}" ]] || { log_warn "Cannot find cluster ${FLEET_TARGET_CLUSTER} — skipping CI secret seeding"; return 0; }

  ds_kc=$(mktemp /tmp/ds-kubeconfig.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -f '${ds_kc}'" RETURN
  rancher_api POST "/v3/clusters/${cluster_id}?action=generateKubeconfig" | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['config'])" > "${ds_kc}" 2>/dev/null
  [[ -s "${ds_kc}" ]] || { log_warn "Could not get downstream kubeconfig — skipping CI secret seeding"; return 0; }

  # Helper: exec vault on downstream cluster
  _vexec() {
    local root_token
    root_token=$(kubectl --kubeconfig="${ds_kc}" get secret vault-init-keys -n vault \
      -o jsonpath='{.data.init\.json}' 2>/dev/null | base64 -d | \
      grep -o '"root_token"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
    [[ -n "${root_token}" ]] || { log_warn "Cannot read Vault root token — skipping"; return 1; }
    kubectl --kubeconfig="${ds_kc}" exec -n vault vault-0 -- env \
      VAULT_ADDR=http://127.0.0.1:8200 \
      VAULT_TOKEN="${root_token}" \
      vault "$@"
  }

  # Seed Harvester kubeconfig (for terraform-runner)
  local existing
  existing=$(_vexec kv get -field=kubeconfig kv/services/ci/harvester-kubeconfig 2>/dev/null || true)
  if [[ -n "${existing}" ]]; then
    log_ok "Harvester kubeconfig already in Vault"
  else
    local kc_content=""

    # Try 1: Fetch from Rancher API (Harvester is a registered cluster)
    local harvester_id
    harvester_id=$(rancher_api GET "/v3/clusters" | python3 -c "
import json,sys
for c in json.load(sys.stdin).get('data',[]):
    if c.get('name') not in ('local','${FLEET_TARGET_CLUSTER}','') and c.get('state')=='active':
        print(c['id'])
        break
" 2>/dev/null || echo "")

    if [[ -n "${harvester_id}" ]]; then
      kc_content=$(rancher_api POST "/v3/clusters/${harvester_id}?action=generateKubeconfig" | \
        python3 -c "import json,sys; print(json.load(sys.stdin).get('config',''))" 2>/dev/null || echo "")
      if [[ -n "${kc_content}" ]]; then
        log_info "Fetched Harvester kubeconfig from Rancher API (cluster ${harvester_id})"
      fi
    fi

    # Try 2: Fall back to local file from .env
    if [[ -z "${kc_content}" && -n "${HARVESTER_KUBECONFIG_PATH:-}" ]]; then
      local kc_path="${HARVESTER_KUBECONFIG_PATH}"
      if [[ "${kc_path}" != /* ]]; then
        kc_path="${FLEET_DIR}/${kc_path#./}"
      fi
      if [[ -f "${kc_path}" ]]; then
        kc_content=$(cat "${kc_path}")
        log_info "Using Harvester kubeconfig from ${kc_path}"
      fi
    fi

    if [[ -n "${kc_content}" ]]; then
      _vexec kv put kv/services/ci/harvester-kubeconfig kubeconfig="${kc_content}"
      log_ok "Seeded Harvester kubeconfig into Vault (services/ci/harvester-kubeconfig)"
    else
      log_warn "Could not obtain Harvester kubeconfig (not in Rancher API or HARVESTER_KUBECONFIG_PATH) — gitlab-runners will not sync"
    fi
  fi

  # Seed GitLab Enterprise license (activation code or offline license file)
  # Priority: offline license file (GITLAB_LICENSE_FILE) > online activation code (GITLAB_LICENSE)
  # Uses kv patch to backfill new keys without clobbering existing values.
  local license_check
  license_check=$(_vexec kv get -field=activation-code kv/services/gitlab 2>/dev/null || true)
  local license_file_check
  license_file_check=$(_vexec kv get -field=license-file kv/services/gitlab 2>/dev/null || true)

  if [[ -n "${GITLAB_LICENSE_FILE:-}" ]]; then
    if [[ ! -f "${GITLAB_LICENSE_FILE}" ]]; then
      log_err "GITLAB_LICENSE_FILE points to '${GITLAB_LICENSE_FILE}' but file does not exist"
      return 1
    fi
    local license_content
    license_content=$(<"${GITLAB_LICENSE_FILE}")
    _vexec kv put kv/services/gitlab activation-code="" license-file="${license_content}"
    log_ok "Seeded GitLab offline license file into Vault (services/gitlab)"
  elif [[ -n "${GITLAB_LICENSE:-}" ]]; then
    if [[ -n "${license_check}" ]]; then
      # Backfill license-file key if missing from prior deployment
      _vexec kv patch kv/services/gitlab license-file="" 2>/dev/null || true
      log_ok "GitLab activation code already in Vault (ensured license-file key exists)"
    else
      _vexec kv put kv/services/gitlab activation-code="${GITLAB_LICENSE}" license-file=""
      log_ok "Seeded GitLab activation code into Vault (services/gitlab)"
    fi
  elif [[ -n "${license_check}" ]]; then
    # Existing deployment — backfill license-file key if missing
    _vexec kv patch kv/services/gitlab license-file="" 2>/dev/null || true
    log_ok "GitLab license already in Vault (ensured license-file key exists)"
  else
    _vexec kv put kv/services/gitlab activation-code="" license-file=""
    log_warn "No GITLAB_LICENSE or GITLAB_LICENSE_FILE in .env — seeded empty placeholders (Community Edition)"
  fi

  # Seed GitHub mirror credentials (for sanitized push from CI)
  if [[ -n "${GITHUB_API_TOKEN:-}" ]]; then
    local gh_check
    gh_check=$(_vexec kv get -field=api-token kv/services/ci/github-mirror 2>/dev/null || true)
    if [[ -n "${gh_check}" ]]; then
      log_ok "GitHub mirror credentials already in Vault"
    else
      local ssh_key=""
      if [[ -n "${GITHUB_SSH_PRIVATE_KEY_FILE:-}" && -f "${GITHUB_SSH_PRIVATE_KEY_FILE}" ]]; then
        ssh_key=$(cat "${GITHUB_SSH_PRIVATE_KEY_FILE}")
      fi
      _vexec kv put kv/services/ci/github-mirror \
        api-token="${GITHUB_API_TOKEN}" \
        mirror-url="${GITHUB_MIRROR_URL:-}" \
        mirror-repo="${GITHUB_MIRROR_REPO:-}" \
        ssh-private-key="${ssh_key}"
      log_ok "Seeded GitHub mirror credentials into Vault (services/ci/github-mirror)"
    fi
  fi

  # NOTE: Platform GDT (Group Deploy Token) for CI push to platform-deployments
  # is created automatically by the gitlab-admin-setup Job via Rails runner.
  # No .env variables needed — the Job creates the token and seeds it to Vault
  # at kv/services/ci/platform-deploy-token (username + token).
}

# NOTE: seed_ci_secrets runs in the post-deploy phase (Vault must exist first)

# --- Seed cluster-autoscaler secrets on downstream cluster ---
# The autoscaler Deployment references two Secrets that cannot be managed by
# Fleet (they contain Rancher API tokens and the full CA chain). We seed them
# once; they persist across re-deploys because the namespace survives.
seed_cluster_autoscaler_secrets() {
  log_info "Checking cluster-autoscaler secrets..."

  local cluster_id ds_kc
  cluster_id=$(rancher_api GET "/v3/clusters" | python3 -c "
import json,sys
[print(c['id']) for c in json.load(sys.stdin).get('data',[]) if c.get('name')=='${FLEET_TARGET_CLUSTER}']
" 2>/dev/null | head -1)
  [[ -n "${cluster_id}" ]] || { log_warn "Cannot find cluster ${FLEET_TARGET_CLUSTER} — skipping autoscaler secrets"; return 0; }

  ds_kc=$(mktemp /tmp/ds-kubeconfig.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -f '${ds_kc}'" RETURN
  rancher_api POST "/v3/clusters/${cluster_id}?action=generateKubeconfig" | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['config'])" > "${ds_kc}" 2>/dev/null
  [[ -s "${ds_kc}" ]] || { log_warn "Could not get downstream kubeconfig — skipping autoscaler secrets"; return 0; }

  # Ensure namespace exists
  kubectl --kubeconfig="${ds_kc}" create namespace cluster-autoscaler --dry-run=client -o yaml | \
    kubectl --kubeconfig="${ds_kc}" apply -f - 2>/dev/null

  # cloud-config: Rancher API connection for autoscaler
  if kubectl --kubeconfig="${ds_kc}" get secret cluster-autoscaler-cloud-config -n cluster-autoscaler &>/dev/null; then
    log_ok "cluster-autoscaler-cloud-config already exists"
  else
    local cloud_config_tmp
    cloud_config_tmp=$(mktemp)
    cat > "${cloud_config_tmp}" <<CLOUDCFG
url: ${RANCHER_URL}
token: ${RANCHER_TOKEN}
clusterName: ${FLEET_TARGET_CLUSTER}
clusterNamespace: ${FLEET_NAMESPACE}
CLOUDCFG
    kubectl --kubeconfig="${ds_kc}" -n cluster-autoscaler \
      create secret generic cluster-autoscaler-cloud-config \
      --from-file=cloud-config="${cloud_config_tmp}" \
      --dry-run=client -o yaml | \
      kubectl --kubeconfig="${ds_kc}" apply -f -
    rm -f "${cloud_config_tmp}"
    log_ok "cluster-autoscaler-cloud-config seeded"
  fi

  # ca-cert: Combined CA bundle for trusting Rancher TLS
  if kubectl --kubeconfig="${ds_kc}" get secret cluster-autoscaler-ca-cert -n cluster-autoscaler &>/dev/null; then
    log_ok "cluster-autoscaler-ca-cert already exists"
  else
    local ca_bundle_tmp
    ca_bundle_tmp=$(mktemp)
    local rancher_host
    rancher_host=$(echo "${RANCHER_URL}" | sed 's|https://||; s|/.*||')
    openssl s_client -connect "${rancher_host}:443" -servername "${rancher_host}" \
      -showcerts </dev/null 2>/dev/null | \
      sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > "${ca_bundle_tmp}"
    # Append root CA
    local root_ca_pem="${ROOT_CA_PEM_FILE:-./root-ca.pem}"
    if [[ "${root_ca_pem}" != /* ]]; then
      root_ca_pem="${FLEET_DIR}/${root_ca_pem#./}"
    fi
    if [[ -f "${root_ca_pem}" ]]; then
      cat "${root_ca_pem}" >> "${ca_bundle_tmp}"
    fi
    # Append system CAs if available
    for sys_ca in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do
      if [[ -f "${sys_ca}" ]]; then
        cat "${sys_ca}" >> "${ca_bundle_tmp}"
        break
      fi
    done
    kubectl --kubeconfig="${ds_kc}" -n cluster-autoscaler \
      create secret generic cluster-autoscaler-ca-cert \
      --from-file=ca.crt="${ca_bundle_tmp}" \
      --dry-run=client -o yaml | \
      kubectl --kubeconfig="${ds_kc}" apply --server-side --force-conflicts -f -
    rm -f "${ca_bundle_tmp}"
    log_ok "cluster-autoscaler-ca-cert seeded"
  fi

  rm -f "${ds_kc}"
}

seed_cluster_autoscaler_secrets

# --- Apply Traefik HelmChartConfig on downstream cluster ---
# RKE2 manages Traefik as a system add-on; HelmChartConfig patches it for
# dashboard access, Gateway API, CA trust, and SSH port exposure.
# This resource is owned by RKE2's addon manager and cannot be Fleet-managed.
apply_traefik_helmchartconfig() {
  log_info "Checking Traefik HelmChartConfig..."
  local svcs_dir
  svcs_dir="$(dirname "${FLEET_DIR}")"
  local traefik_hcc="${svcs_dir}/services/traefik-dashboard/helmchartconfig.yaml"
  if [[ ! -f "${traefik_hcc}" ]]; then
    log_warn "Traefik HelmChartConfig not found at ${traefik_hcc} — skipping"
    return 0
  fi

  local cluster_id ds_kc
  cluster_id=$(rancher_api GET "/v3/clusters" | python3 -c "
import json,sys
[print(c['id']) for c in json.load(sys.stdin).get('data',[]) if c.get('name')=='${FLEET_TARGET_CLUSTER}']
" 2>/dev/null | head -1)
  [[ -n "${cluster_id}" ]] || { log_warn "Cannot find cluster — skipping Traefik HelmChartConfig"; return 0; }

  ds_kc=$(mktemp /tmp/ds-kubeconfig.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -f '${ds_kc}'" RETURN
  rancher_api POST "/v3/clusters/${cluster_id}?action=generateKubeconfig" | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['config'])" > "${ds_kc}" 2>/dev/null
  [[ -s "${ds_kc}" ]] || { log_warn "Could not get downstream kubeconfig — skipping Traefik HelmChartConfig"; return 0; }

  sed "s/CHANGEME_TRAEFIK_LB_IP/${TRAEFIK_LB_IP}/g" "${traefik_hcc}" | \
    kubectl --kubeconfig="${ds_kc}" apply --server-side --force-conflicts -f -
  log_ok "Traefik HelmChartConfig applied (dashboard + Gateway API + CA trust)"

  rm -f "${ds_kc}"
}

apply_traefik_helmchartconfig

# --- Sign Vault intermediate CA CSR ---
# vault-init generates a CSR and saves it to vault/vault-intermediate-csr Secret.
# This function signs it with the offline Root CA key, imports the chain into Vault,
# and creates the PKI signing role. Idempotent: skips if already signed.
sign_vault_intermediate_csr() {
  log_info "Checking Vault intermediate CA..."

  local svcs_dir
  svcs_dir="$(dirname "${FLEET_DIR}")"
  local root_ca_pem="${svcs_dir}/services/pki/roots/root-ca.pem"
  local root_ca_key="${svcs_dir}/services/pki/roots/root-ca-key.pem"

  if [[ ! -f "${root_ca_pem}" || ! -f "${root_ca_key}" ]]; then
    log_warn "Root CA files not found (${root_ca_pem}, ${root_ca_key}) — skipping CSR signing"
    return 0
  fi

  local cluster_id ds_kc
  cluster_id=$(rancher_api GET "/v3/clusters" | python3 -c "
import json,sys
[print(c['id']) for c in json.load(sys.stdin).get('data',[]) if c.get('name')=='${FLEET_TARGET_CLUSTER}']
" 2>/dev/null | head -1)
  [[ -n "${cluster_id}" ]] || { log_warn "Cannot find cluster — skipping CSR signing"; return 0; }

  ds_kc=$(mktemp /tmp/ds-kubeconfig.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -f '${ds_kc}'" RETURN
  rancher_api POST "/v3/clusters/${cluster_id}?action=generateKubeconfig" | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['config'])" > "${ds_kc}" 2>/dev/null
  [[ -s "${ds_kc}" ]] || { log_warn "Could not get downstream kubeconfig — skipping CSR signing"; return 0; }

  # Wait for vault-0 to be ready (up to 15 min on fresh deploy)
  log_info "Waiting for vault-0 to be ready..."
  local vault_ready=false
  for _i in $(seq 1 180); do
    if kubectl --kubeconfig="${ds_kc}" -n vault wait pod/vault-0 --for=condition=Ready --timeout=5s &>/dev/null; then
      vault_ready=true
      break
    fi
    sleep 5
  done
  [[ "${vault_ready}" == true ]] || { log_warn "vault-0 not ready after 15 minutes — skipping CSR signing"; rm -f "${ds_kc}"; return 0; }

  # Get root token
  local vault_root_token
  vault_root_token=$(kubectl --kubeconfig="${ds_kc}" -n vault get secret vault-init-keys \
    -o jsonpath='{.data.init\.json}' 2>/dev/null | base64 -d | \
    grep -o '"root_token"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"')
  [[ -n "${vault_root_token}" ]] || { log_warn "Cannot read Vault root token — skipping CSR signing"; rm -f "${ds_kc}"; return 0; }

  # Check if already signed
  local int_check
  int_check=$(kubectl --kubeconfig="${ds_kc}" -n vault exec vault-0 -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${vault_root_token}" \
    vault read -format=json pki_int/ca/pem 2>/dev/null || true)
  if echo "${int_check}" | grep -q "BEGIN CERTIFICATE"; then
    log_ok "Intermediate CA already signed"
    rm -f "${ds_kc}"
    return 0
  fi

  # Wait for CSR Secret (vault-init Job must run: unseal, init KV/PKI, generate CSR)
  log_info "Waiting for vault-init to generate intermediate CSR..."
  local csr_found=false
  for _i in $(seq 1 90); do
    if kubectl --kubeconfig="${ds_kc}" -n vault get secret vault-intermediate-csr &>/dev/null; then
      csr_found=true
      break
    fi
    sleep 10
  done
  if [[ "${csr_found}" != true ]]; then
    log_warn "vault-intermediate-csr Secret not found after 15 minutes — skipping"
    rm -f "${ds_kc}"
    return 0
  fi

  # Read CSR
  local csr_pem
  csr_pem=$(kubectl --kubeconfig="${ds_kc}" -n vault get secret vault-intermediate-csr \
    -o jsonpath='{.data.csr\.pem}' | base64 -d)
  [[ -n "${csr_pem}" ]] || { log_warn "CSR is empty — skipping"; rm -f "${ds_kc}"; return 0; }
  log_ok "Intermediate CSR retrieved from cluster"

  # Sign CSR locally with Root CA
  local csr_tmp signed_tmp ext_tmp chain_tmp
  csr_tmp=$(mktemp)
  signed_tmp=$(mktemp)
  ext_tmp=$(mktemp)
  chain_tmp=$(mktemp)

  echo "${csr_pem}" > "${csr_tmp}"
  cat > "${ext_tmp}" <<'EXTCONF'
[v3_intermediate_ca]
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EXTCONF

  log_info "Signing intermediate CSR with offline Root CA key..."
  openssl x509 -req -days 5475 \
    -in "${csr_tmp}" \
    -CA "${root_ca_pem}" \
    -CAkey "${root_ca_key}" \
    -CAcreateserial \
    -out "${signed_tmp}" \
    -sha256 \
    -extfile "${ext_tmp}" \
    -extensions v3_intermediate_ca

  openssl verify -CAfile "${root_ca_pem}" "${signed_tmp}" || { log_error "Chain verification failed"; rm -f "${csr_tmp}" "${signed_tmp}" "${ext_tmp}" "${chain_tmp}" "${ds_kc}"; return 1; }
  log_ok "Intermediate CA signed and verified"

  # Build full chain (intermediate + root)
  cat "${signed_tmp}" "${root_ca_pem}" > "${chain_tmp}"

  # Import signed chain into Vault
  log_info "Importing signed intermediate chain into Vault..."
  local chain_b64
  chain_b64=$(base64 -w0 "${chain_tmp}")
  kubectl --kubeconfig="${ds_kc}" -n vault exec vault-0 -- \
    sh -c "echo '${chain_b64}' | base64 -d > /tmp/intermediate-chain.pem"
  kubectl --kubeconfig="${ds_kc}" -n vault exec vault-0 -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${vault_root_token}" \
    vault write pki_int/intermediate/set-signed certificate=@/tmp/intermediate-chain.pem
  log_ok "Intermediate chain imported into Vault"

  # Create PKI signing role
  local domain="${DOMAIN}"
  local domain_dot="${domain//./-dot-}"
  kubectl --kubeconfig="${ds_kc}" -n vault exec vault-0 -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${vault_root_token}" \
    vault write "pki_int/roles/${domain_dot}" \
      allowed_domains="${domain},cluster.local" \
      allow_subdomains=true \
      allow_bare_domains=true \
      max_ttl=720h \
      require_cn=false \
      generate_lease=true
  log_ok "PKI role ${domain_dot} created"

  rm -f "${csr_tmp}" "${signed_tmp}" "${ext_tmp}" "${chain_tmp}" "${ds_kc}"
}

# NOTE: sign_vault_intermediate_csr runs in the post-deploy phase (Vault must exist first)

# --- Re-inject Harbor Valkey password post-deploy ---
# On first deploy, harbor-core is created with a placeholder Redis password
# because Valkey doesn't exist yet. This function waits for Valkey, fetches
# the real password, and re-creates the harbor-core HelmOp.
reinject_harbor_valkey_password() {
  log_info "Waiting for Harbor Valkey to come up..."

  local cluster_id ds_kc_valkey
  cluster_id=$(rancher_api GET "/v3/clusters" 2>/dev/null | python3 -c "
import json,sys
[print(c['id']) for c in json.load(sys.stdin).get('data',[]) if c.get('name')=='${FLEET_TARGET_CLUSTER}']
" 2>/dev/null | head -1)
  [[ -n "${cluster_id}" ]] || { log_warn "Cannot find cluster — skipping Valkey re-injection"; return 0; }

  ds_kc_valkey=$(mktemp /tmp/ds-kubeconfig-valkey.XXXXXX)
  rancher_api POST "/v3/clusters/${cluster_id}?action=generateKubeconfig" 2>/dev/null | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['config'])" > "${ds_kc_valkey}" 2>/dev/null
  if [[ ! -s "${ds_kc_valkey}" ]]; then
    log_warn "Could not get downstream kubeconfig — skipping Valkey re-injection"
    rm -f "${ds_kc_valkey}"
    return 0
  fi

  # Wait for harbor-valkey-credentials secret (up to 20 min)
  local valkey_ready=false
  for _i in $(seq 1 120); do
    if kubectl --kubeconfig="${ds_kc_valkey}" get secret harbor-valkey-credentials -n harbor &>/dev/null; then
      valkey_ready=true
      break
    fi
    sleep 10
  done
  if [[ "${valkey_ready}" != true ]]; then
    log_warn "harbor-valkey-credentials not found after 20 minutes — run with --group 30-harbor to re-inject later"
    rm -f "${ds_kc_valkey}"
    return 0
  fi

  local valkey_pw
  valkey_pw=$(kubectl --kubeconfig="${ds_kc_valkey}" get secret harbor-valkey-credentials -n harbor \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  rm -f "${ds_kc_valkey}"

  if [[ -z "${valkey_pw}" ]]; then
    log_warn "harbor-valkey-credentials password empty — skipping re-injection"
    return 0
  fi

  log_ok "Valkey password fetched — re-deploying harbor-core HelmOp"

  # Find and re-create the harbor-core entry
  for entry in "${HELMOP_DEFS[@]}"; do
    IFS='|' read -r name oci_repo version namespace release depends values_file <<< "${entry}"
    if [[ "${name}" == "harbor-core" ]]; then
      create_helmop "${name}" "${oci_repo}" "${version}" \
        "${namespace}" "${release}" "${depends}" "${values_file}"
      break
    fi
  done

  log_ok "harbor-core re-deployed with real Valkey password"
}

# ============================================================
# Auto-cleanup completed init Jobs before deploy (spec-hash aware)
# ============================================================
# Kubernetes Jobs are immutable. Fleet cannot patch them, causing ErrApplied.
#
# Strategy:
#   - Failed / crash-looping Jobs: always delete (broken, need recreation)
#   - Completed Jobs: compare fleet.example.com/spec-hash annotation against
#     the hash of the rendered manifest. Only delete if the spec changed.
#   - Legacy Jobs without annotation: delete (first deploy with hashing)
cleanup_completed_init_jobs() {
  # Map of group → "namespace/job-name" pairs (must match all Job manifests)
  declare -A GROUP_JOBS=(
    ["05-pki-secrets"]="vault/vault-init vault/vault-init-wait"
    ["10-identity"]="keycloak/keycloak-init keycloak/keycloak-config database/database-init"
    ["20-monitoring"]="monitoring/monitoring-init"
    ["30-harbor"]="harbor/harbor-init harbor/harbor-oidc-setup minio/minio-init"
    ["40-gitops"]="argocd/argocd-init argocd/argocd-gitlab-setup argo-rollouts/rollouts-init argo-workflows/workflows-init"
    ["50-gitlab"]="gitlab/gitlab-init gitlab/gitlab-ready gitlab/vault-jwt-auth-setup gitlab/gitlab-admin-setup gitlab-runners/runner-secrets-setup"
  )

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

  local rendered_dir="${FLEET_DIR}/rendered"

  # --- Get downstream kubeconfig ---
  local cluster_id ds_kc
  cluster_id=$(rancher_api GET "/v3/clusters" 2>/dev/null | \
    python3 -c "
import json,sys
[print(c['id']) for c in json.load(sys.stdin).get('data',[]) if c.get('name')=='${FLEET_TARGET_CLUSTER}']
" 2>/dev/null | head -1)

  if [[ -z "${cluster_id:-}" ]]; then
    log_warn "Cannot find cluster ${FLEET_TARGET_CLUSTER} — skipping Job cleanup"
    return 0
  fi

  ds_kc=$(mktemp /tmp/ds-kubeconfig-cleanup.XXXXXX)
  rancher_api POST "/v3/clusters/${cluster_id}?action=generateKubeconfig" 2>/dev/null | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['config'])" > "${ds_kc}" 2>/dev/null || true

  if [[ ! -s "${ds_kc}" ]]; then
    log_warn "Could not get downstream kubeconfig — skipping Job cleanup"
    rm -f "${ds_kc}"
    return 0
  fi

  # --- Determine which groups to clean ---
  local groups_to_clean=()
  if [[ -n "${SINGLE_GROUP}" ]]; then
    if [[ -z "${GROUP_JOBS[${SINGLE_GROUP}]+set}" ]]; then
      log_info "Group '${SINGLE_GROUP}' has no init Jobs to clean up"
      rm -f "${ds_kc}"
      return 0
    fi
    groups_to_clean=("${SINGLE_GROUP}")
  else
    groups_to_clean=("${!GROUP_JOBS[@]}")
  fi

  # --- Iterate Jobs and apply cleanup strategy ---
  local cleaned=0 skipped=0
  for group in "${groups_to_clean[@]}"; do
    local jobs="${GROUP_JOBS[${group}]:-}"
    [[ -z "${jobs}" ]] && continue

    local job_entries
    IFS=' ' read -ra job_entries <<< "${jobs}"
    for entry in "${job_entries[@]}"; do
      local ns="${entry%%/*}"
      local job_name="${entry##*/}"

      # Check Job status on downstream cluster
      local complete failed restarts
      complete=$(kubectl --kubeconfig="${ds_kc}" get job "${job_name}" -n "${ns}" \
        -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "")
      failed=$(kubectl --kubeconfig="${ds_kc}" get job "${job_name}" -n "${ns}" \
        -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")
      restarts=$(kubectl --kubeconfig="${ds_kc}" get pods -n "${ns}" -l "job-name=${job_name}" \
        -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")

      # Always delete failed or crash-looping Jobs
      if [[ "${failed}" == "True" ]]; then
        kubectl --kubeconfig="${ds_kc}" delete job "${job_name}" -n "${ns}" --ignore-not-found &>/dev/null
        log_info "Deleted failed Job: ${ns}/${job_name}"
        cleaned=$((cleaned + 1))
        continue
      fi
      if [[ "${restarts:-0}" -gt 3 ]]; then
        kubectl --kubeconfig="${ds_kc}" delete job "${job_name}" -n "${ns}" --ignore-not-found &>/dev/null
        log_info "Deleted crash-looping Job (${restarts} restarts): ${ns}/${job_name}"
        cleaned=$((cleaned + 1))
        continue
      fi

      # For completed Jobs: compare spec-hash annotation
      if [[ "${complete}" == "True" ]]; then
        local live_hash desired_hash
        live_hash=$(kubectl --kubeconfig="${ds_kc}" get job "${job_name}" -n "${ns}" \
          -o jsonpath='{.metadata.annotations.fleet\.aegisgroup\.ch/spec-hash}' 2>/dev/null || echo "")

        # Compute desired hash from rendered manifest (excluding the annotation line itself)
        local manifest_file="${rendered_dir}/${JOB_MANIFEST_FILES[${entry}]:-}"
        if [[ -n "${manifest_file}" && -f "${manifest_file}" ]]; then
          desired_hash=$(grep -v 'fleet\.aegisgroup\.ch/spec-hash:' "${manifest_file}" | sha256sum | awk '{print $1}')
        else
          desired_hash="UNKNOWN"
        fi

        if [[ -z "${live_hash}" ]]; then
          # Legacy Job without annotation — delete so Fleet recreates with hash
          kubectl --kubeconfig="${ds_kc}" delete job "${job_name}" -n "${ns}" --ignore-not-found &>/dev/null
          log_info "Deleted completed Job (no spec-hash, legacy): ${ns}/${job_name}"
          cleaned=$((cleaned + 1))
        elif [[ "${live_hash}" != "${desired_hash}" ]]; then
          # Hash mismatch — spec changed, delete to allow recreation
          kubectl --kubeconfig="${ds_kc}" delete job "${job_name}" -n "${ns}" --ignore-not-found &>/dev/null
          log_info "Deleted completed Job (spec changed): ${ns}/${job_name}"
          cleaned=$((cleaned + 1))
        else
          # Hash matches — spec unchanged, skip deletion
          skipped=$((skipped + 1))
        fi
      fi
    done
  done

  rm -f "${ds_kc}"

  if [[ ${cleaned} -gt 0 || ${skipped} -gt 0 ]]; then
    log_ok "Job cleanup: ${cleaned} deleted, ${skipped} unchanged (skipped)"
  fi
}

if [[ "${STATUS_MODE}" != true && "${WATCH_MODE}" != true && "${DELETE_MODE}" != true && "${PURGE_MODE}" != true ]]; then
  cleanup_completed_init_jobs
fi

# Deploy HelmOps
deployed=0
failed=0

for entry in "${HELMOP_DEFS[@]}"; do
  IFS='|' read -r name oci_repo version namespace release depends values_file <<< "${entry}"

  # Filter by group if specified
  if [[ -n "${SINGLE_GROUP}" ]]; then
    # Map name prefixes to groups
    case "${name}" in
      operators-*)  group="00-operators" ;;
      pki-*)        group="05-pki-secrets" ;;
      identity-*)   group="10-identity" ;;
      infra-auth-*) group="11-infra-auth" ;;
      monitoring-*) group="20-monitoring" ;;
      harbor-*|minio) group="30-harbor" ;;
      gitops-*)     group="40-gitops" ;;
      gitlab-*)     group="50-gitlab" ;;
      *)            group="unknown" ;;
    esac
    if [[ "${group}" != "${SINGLE_GROUP}" ]]; then
      continue
    fi
  fi

  if create_helmop "${name}" "${oci_repo}" "${version}" \
       "${namespace}" "${release}" "${depends}" "${values_file}"; then
    deployed=$((deployed + 1))
  else
    failed=$((failed + 1))
    die "Stopping deployment due to failure on ${name}"
  fi
done

echo ""
echo -e "${BOLD}Deployment summary:${NC}"
echo -e "  ${GREEN}Created/Updated:${NC} ${deployed}"
[[ ${failed} -gt 0 ]] && echo -e "  ${RED}Failed:${NC} ${failed}"
echo ""

if [[ "${DRY_RUN}" != true ]]; then
  log_info "HelmOps created. Fleet will generate bundles and deploy to ${FLEET_TARGET_CLUSTER}."

  # --- Post-deploy convergence phase ---
  # Services that need post-deploy actions: Vault CSR signing, Harbor Valkey password.
  # These couldn't run in the pre-deploy phase because the services didn't exist yet.

  if [[ -z "${SINGLE_GROUP}" ]]; then
    echo ""
    echo -e "${BOLD}${BLUE}--- Post-Deploy Convergence Phase ---${NC}"
    echo ""

    # 0. Heal stuck bundles (Fleet sometimes fails to apply resources on first deploy)
    heal_stuck_bundles 300 || log_warn "Some bundles may need manual investigation"

    # 1. Sign Vault intermediate CSR (Vault must be running and init must generate CSR)
    sign_vault_intermediate_csr

    # 2. Seed CI secrets into Vault (Vault must be initialized and unsealed)
    seed_ci_secrets

    # 3. Re-deploy harbor-core with real Valkey password once Valkey is up
    reinject_harbor_valkey_password

    echo ""
    echo -e "${BOLD}${BLUE}--- Post-Deploy Phase Complete ---${NC}"
    echo ""
  fi

  log_info "Monitor with: $0 --status"
  log_info "View in Rancher UI: Continuous Delivery → App Bundles"
fi
