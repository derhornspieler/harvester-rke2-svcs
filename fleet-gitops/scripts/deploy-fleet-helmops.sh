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
#   - Helm charts pushed to oci://harbor.example.com/helm/ (push-charts.sh)
#   - Raw manifest bundles pushed to oci://harbor.example.com/fleet/ (push-bundles.sh)
#   - Root CA secret pre-seeded on downstream cluster (deploy.sh handles this)

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_DIR="$(dirname "${SCRIPT_DIR}")"

HARBOR="harbor.example.com"

# Source .env early so BUNDLE_VERSION is available for HELMOP_DEFS array
if [[ -f "${FLEET_DIR}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${FLEET_DIR}/.env"
  set +a
fi
BUNDLE_VERSION="${BUNDLE_VERSION:-1.0.0}"

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
  "operators-prometheus-crds|oci://${HARBOR}/helm/prometheus-operator-crds|27.0.0|monitoring|prometheus-operator-crds||"
  "operators-cnpg|oci://${HARBOR}/helm/cloudnative-pg|0.27.1|cnpg-system|cnpg||00-operators/cnpg-operator/values.yaml"
  "operators-redis|oci://${HARBOR}/helm/redis-operator|0.23.0|redis-operator|redis-operator||00-operators/redis-operator/values.yaml"
  "operators-node-labeler|oci://${HARBOR}/fleet/operators-node-labeler|${BUNDLE_VERSION}|node-labeler|operators-node-labeler|operators-prometheus-crds|"
  "operators-storage-autoscaler|oci://${HARBOR}/fleet/operators-storage-autoscaler|${BUNDLE_VERSION}|storage-autoscaler|operators-storage-autoscaler|operators-prometheus-crds|"
  "operators-cluster-autoscaler|oci://${HARBOR}/fleet/operators-cluster-autoscaler|${BUNDLE_VERSION}|cluster-autoscaler|operators-cluster-autoscaler|operators-prometheus-crds|"
  "operators-gateway-api-crds|oci://${HARBOR}/fleet/operators-gateway-api-crds|${BUNDLE_VERSION}|kube-system|operators-gateway-api-crds||"

  # 05-pki-secrets (depends on operators)
  "pki-cert-manager|oci://${HARBOR}/helm/cert-manager|v1.19.4|cert-manager|cert-manager|operators-cnpg|05-pki-secrets/cert-manager/values.yaml"
  "pki-vault|oci://${HARBOR}/helm/vault|0.32.0|vault|vault|operators-cnpg|05-pki-secrets/vault/values.yaml"
  "pki-vault-init|oci://${HARBOR}/fleet/pki-vault-init|${BUNDLE_VERSION}|vault|pki-vault-init|pki-vault|"
  "pki-vault-unsealer|oci://${HARBOR}/fleet/pki-vault-unsealer|${BUNDLE_VERSION}|vault|pki-vault-unsealer|pki-vault-init|"
  "pki-vault-pki-issuer|oci://${HARBOR}/fleet/pki-vault-pki-issuer|${BUNDLE_VERSION}|cert-manager|pki-vault-pki-issuer|pki-vault-init,pki-cert-manager|"
  "pki-external-secrets|oci://${HARBOR}/helm/external-secrets|2.0.1|external-secrets|external-secrets|pki-vault-init|05-pki-secrets/external-secrets/values.yaml"

  # 10-identity (depends on pki)
  "identity-cnpg-keycloak|oci://${HARBOR}/fleet/identity-cnpg-keycloak|${BUNDLE_VERSION}|database|identity-cnpg-keycloak|pki-external-secrets,operators-cnpg|"
  "identity-keycloak|oci://${HARBOR}/fleet/identity-keycloak|${BUNDLE_VERSION}|keycloak|identity-keycloak|identity-cnpg-keycloak,operators-prometheus-crds|"
  "identity-keycloak-config|oci://${HARBOR}/fleet/identity-keycloak-config|${BUNDLE_VERSION}|keycloak|identity-keycloak-config|identity-keycloak|"
  # NOT YET: LDAP federation requires FreeIPA to be running
  #"identity-keycloak-ldap-federation|oci://${HARBOR}/fleet/identity-keycloak-ldap-federation|${BUNDLE_VERSION}|keycloak|identity-keycloak-ldap-federation|identity-keycloak-config|"

  # 15-dns (depends on pki — FreeIPA must be running externally)
  # NOT YET: external-dns requires FreeIPA to be running
  #"dns-external-dns-secrets|oci://${HARBOR}/fleet/dns-external-dns-secrets|${BUNDLE_VERSION}|external-dns|dns-external-dns-secrets|pki-external-secrets|"
  #"dns-external-dns|oci://${HARBOR}/helm/external-dns|1.16.1|external-dns|external-dns|dns-external-dns-secrets|15-dns/external-dns/values.yaml"

  # 20-monitoring (depends on pki + identity — waits for full identity stack)
  "monitoring-cnpg-grafana|oci://${HARBOR}/fleet/monitoring-cnpg-grafana|${BUNDLE_VERSION}|database|monitoring-cnpg-grafana|pki-external-secrets,operators-cnpg,identity-keycloak-config|"
  "monitoring-secrets|oci://${HARBOR}/fleet/monitoring-secrets|${BUNDLE_VERSION}|monitoring|monitoring-secrets|pki-external-secrets,identity-keycloak-config|"
  "monitoring-loki|oci://${HARBOR}/fleet/monitoring-loki|${BUNDLE_VERSION}|monitoring|monitoring-loki|identity-keycloak-config|"
  "monitoring-alloy|oci://${HARBOR}/fleet/monitoring-alloy|${BUNDLE_VERSION}|monitoring|monitoring-alloy|identity-keycloak-config|"
  "monitoring-prometheus-stack|oci://${HARBOR}/helm/kube-prometheus-stack|82.10.0|monitoring|kube-prometheus-stack|monitoring-secrets,monitoring-cnpg-grafana|20-monitoring/kube-prometheus-stack/values.yaml"
  "monitoring-ingress-auth|oci://${HARBOR}/fleet/monitoring-ingress-auth|${BUNDLE_VERSION}|monitoring|monitoring-ingress-auth|monitoring-prometheus-stack|"

  # 30-harbor (depends on pki + identity — waits for full identity stack)
  "minio|oci://${HARBOR}/fleet/minio|${BUNDLE_VERSION}|minio|minio|identity-keycloak-config|"
  "harbor-cnpg|oci://${HARBOR}/fleet/harbor-cnpg-harbor|${BUNDLE_VERSION}|database|harbor-cnpg|identity-keycloak-config,operators-cnpg|"
  "harbor-valkey|oci://${HARBOR}/fleet/harbor-valkey|${BUNDLE_VERSION}|harbor|harbor-valkey|identity-keycloak-config,operators-redis|"
  "harbor-core|oci://${HARBOR}/helm/harbor|1.18.2|harbor|harbor|minio,harbor-cnpg,harbor-valkey|30-harbor/harbor/values.yaml"
  "harbor-manifests|oci://${HARBOR}/fleet/harbor-manifests|${BUNDLE_VERSION}|harbor|harbor-manifests|minio,harbor-cnpg,harbor-valkey|"

  # 40-gitops (depends on pki + identity — waits for full identity stack)
  "gitops-argocd|oci://${HARBOR}/helm/argo-cd|9.4.7|argocd|argocd|identity-keycloak-config|40-gitops/argocd/values.yaml"
  "gitops-argocd-manifests|oci://${HARBOR}/fleet/gitops-argocd-manifests|${BUNDLE_VERSION}|argocd|gitops-argocd-manifests|identity-keycloak-config|"
  "gitops-argo-rollouts|oci://${HARBOR}/helm/argo-rollouts|2.40.6|argo-rollouts|argo-rollouts|identity-keycloak-config|40-gitops/argo-rollouts/values.yaml"
  "gitops-argo-rollouts-manifests|oci://${HARBOR}/fleet/gitops-argo-rollouts-manifests|${BUNDLE_VERSION}|argo-rollouts|gitops-argo-rollouts-manifests|gitops-argo-rollouts|"
  "gitops-argo-workflows|oci://${HARBOR}/helm/argo-workflows|0.47.4|argo-workflows|argo-workflows|identity-keycloak-config|40-gitops/argo-workflows/values.yaml"
  "gitops-argo-workflows-manifests|oci://${HARBOR}/fleet/gitops-argo-workflows-manifests|${BUNDLE_VERSION}|argo-workflows|gitops-argo-workflows-manifests|gitops-argo-workflows|"
  "gitops-analysis-templates|oci://${HARBOR}/fleet/gitops-analysis-templates|${BUNDLE_VERSION}|argo-rollouts|gitops-analysis-templates|identity-keycloak-config|"

  # 50-gitlab (depends on pki + identity + harbor — waits for harbor-core)
  "gitlab-cnpg|oci://${HARBOR}/fleet/gitlab-cnpg-gitlab|${BUNDLE_VERSION}|database|gitlab-cnpg|identity-keycloak-config,operators-cnpg|"
  "gitlab-redis|oci://${HARBOR}/fleet/gitlab-redis|${BUNDLE_VERSION}|gitlab|gitlab-redis|identity-keycloak-config,operators-redis|"
  "gitlab-core|oci://${HARBOR}/helm/gitlab|9.9.2|gitlab|gitlab|gitlab-cnpg,gitlab-redis,harbor-core|50-gitlab/gitlab/values.yaml"
  "gitlab-manifests|oci://${HARBOR}/fleet/gitlab-manifests|${BUNDLE_VERSION}|gitlab|gitlab-manifests|identity-keycloak-config,operators-gateway-api-crds|"
  "gitlab-runners|oci://${HARBOR}/fleet/gitlab-runners|${BUNDLE_VERSION}|gitlab-runners|gitlab-runners|gitlab-core|"
  "gitlab-runner-shared|oci://${HARBOR}/helm/gitlab-runner|0.86.0|gitlab-runners|gitlab-runner-shared|gitlab-runners|50-gitlab/runners/shared-runner-values.yaml"
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
    local values_path="${FLEET_DIR}/${values_file_rel}"
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
    # Get downstream kubeconfig via Rancher API
    local cluster_id
    cluster_id=$(rancher_api GET "/v3/clusters" 2>/dev/null | \
      python3 -c "import json,sys; [print(c['id']) for c in json.load(sys.stdin).get('data',[]) if c.get('name')=='rke2-prod']" 2>/dev/null || true)
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
    --slurpfile values "${values_file_tmp}" \
    '{
      apiVersion: "fleet.cattle.io/v1alpha1",
      kind: "HelmOp",
      metadata: {
        name: $name,
        namespace: "fleet-default"
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
        helmSecretName: "harbor-helm-ca",
        dependsOn: $deps,
        defaultNamespace: $namespace,
        targets: [{clusterName: "rke2-prod"}]
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
  trap 'rm -f "${tmpfile}"' RETURN

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
    python3 -c "import json,sys; [print(c['id']) for c in json.load(sys.stdin).get('data',[]) if c.get('name')=='rke2-prod']" 2>/dev/null || true)

  if [[ -z "${cluster_id}" ]]; then
    log_warn "Could not find rke2-prod cluster — skipping downstream cleanup"
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

  # Delete CRDs that were installed by Fleet bundles
  log_info "Removing Fleet-deployed CRDs..."
  local fleet_crds=(
    "clusters.postgresql.cnpg.io"
    "backups.postgresql.cnpg.io"
    "scheduledbackups.postgresql.cnpg.io"
    "poolers.postgresql.cnpg.io"
    "imagecatalogs.postgresql.cnpg.io"
    "clusterimages.postgresql.cnpg.io"
    "redis.redis.opstreelabs.in"
    "redisclusters.redis.opstreelabs.in"
    "redisreplications.redis.opstreelabs.in"
    "redissentinels.redis.opstreelabs.in"
    "externalsecrets.external-secrets.io"
    "secretstores.external-secrets.io"
    "clustersecretstores.external-secrets.io"
    "certificates.cert-manager.io"
    "certificaterequests.cert-manager.io"
    "clusterissuers.cert-manager.io"
    "issuers.cert-manager.io"
    "orders.acme.cert-manager.io"
    "challenges.acme.cert-manager.io"
    "prometheuses.monitoring.coreos.com"
    "prometheusrules.monitoring.coreos.com"
    "servicemonitors.monitoring.coreos.com"
    "podmonitors.monitoring.coreos.com"
    "alertmanagers.monitoring.coreos.com"
    "alertmanagerconfigs.monitoring.coreos.com"
    "thanosrulers.monitoring.coreos.com"
    "probes.monitoring.coreos.com"
    "scrapeconfigs.monitoring.coreos.com"
    "prometheusagents.monitoring.coreos.com"
  )
  for crd in "${fleet_crds[@]}"; do
    if kubectl --kubeconfig="${ds_kc}" get crd "${crd}" &>/dev/null; then
      kubectl --kubeconfig="${ds_kc}" delete crd "${crd}" --timeout=30s 2>/dev/null || \
        log_warn "Failed to delete CRD ${crd}"
      log_ok "Deleted CRD: ${crd}"
    fi
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
    operators-cluster-autoscaler operators-node-labeler operators-storage-autoscaler operators-gateway-api-crds
    pki-vault-init pki-vault-unsealer pki-vault-pki-issuer
    identity-cnpg-keycloak identity-keycloak identity-keycloak-config
    monitoring-cnpg-grafana monitoring-secrets monitoring-loki monitoring-alloy monitoring-ingress-auth
    minio harbor-cnpg-harbor harbor-valkey harbor-manifests
    gitops-argocd-manifests gitops-argo-rollouts-manifests gitops-argo-workflows-manifests gitops-analysis-templates
    gitlab-cnpg-gitlab gitlab-redis gitlab-manifests gitlab-runners
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
# Show status
# ============================================================
show_status() {
  echo -e "${BOLD}Fleet HelmOp Status:${NC}"
  printf "%-35s %-12s %-8s %s\n" "HELMOP" "STATE" "READY" "MESSAGE"
  printf "%-35s %-12s %-8s %s\n" "------" "-----" "-----" "-------"

  for entry in "${HELMOP_DEFS[@]}"; do
    IFS='|' read -r name _ _ _ _ _ _ <<< "${entry}"

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
except:
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
except:
    print('-')
" 2>/dev/null || echo "-")

    local color="${RED}"
    [[ "${state}" == "active" ]] && color="${GREEN}"
    [[ "${state}" == "NotFound" ]] && color="${YELLOW}"

    printf "%-35s ${color}%-12s${NC} %-8s %s\n" "${name}" "${state}" "${bundle_info}" "${msg}"
  done
}

# ============================================================
# Main
# ============================================================
DRY_RUN=false
DELETE_MODE=false
PURGE_MODE=false
STATUS_MODE=false
SINGLE_GROUP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=true; shift ;;
    --delete)     DELETE_MODE=true; shift ;;
    --purge)      PURGE_MODE=true; shift ;;
    --status)     STATUS_MODE=true; shift ;;
    --group)      SINGLE_GROUP="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--delete] [--purge] [--status] [--group <group>]"
      echo ""
      echo "  --delete   Remove all HelmOps from Fleet (keeps Harbor OCI artifacts)"
      echo "  --purge    Remove HelmOps from Fleet AND delete OCI artifacts from Harbor"
      echo "  --status   Show deployment status"
      echo "  --group    Deploy/delete a single group (e.g., 50-gitlab)"
      echo "  --dry-run  Show CRs without applying"
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

load_config

echo -e "${BOLD}${BLUE}============================================================${NC}"
echo -e "${BOLD}${BLUE}  Fleet GitOps — HelmOp Deployment${NC}"
echo -e "${BOLD}${BLUE}============================================================${NC}"
echo ""

if [[ "${STATUS_MODE}" == true ]]; then
  show_status
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
  log_info "HelmOps created. Fleet will generate bundles and deploy to rke2-prod."
  log_info "Monitor with: $0 --status"
  log_info "View in Rancher UI: Continuous Delivery → App Bundles"
fi
