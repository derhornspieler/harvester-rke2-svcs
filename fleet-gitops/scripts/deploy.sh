#!/usr/bin/env bash
set -euo pipefail

# deploy.sh — Unified Fleet GitOps deployment to a downstream cluster
#
# Pushes Helm charts to Harbor, seeds Root CA on the downstream cluster,
# and creates Fleet Bundle CRs via Rancher API — all in one command.
#
# Usage:
#   ./deploy.sh                     # Full deployment (push + seed + deploy)
#   ./deploy.sh --skip-push         # Skip pushing charts to Harbor
#   ./deploy.sh --dry-run           # Show what would be deployed
#   ./deploy.sh --status            # Show Fleet bundle status
#   ./deploy.sh --delete            # Remove all Fleet bundles
#   ./deploy.sh --bundle 00-operators  # Deploy a single bundle group
#
# Prerequisites:
#   - helm CLI with OCI support
#   - kubectl CLI
#   - jq, python3 with PyYAML
#   - Harbor credentials (helm registry login <HARBOR_HOST>)
#   - Rancher API access (reads from .env file or environment variables)

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_DIR="$(dirname "${SCRIPT_DIR}")"
SVCS_DIR="$(dirname "${FLEET_DIR}")"

# Source .env early so HARBOR_HOST and other variables are available
if [[ -f "${FLEET_DIR}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${FLEET_DIR}/.env"
  set +a
fi
source "${SCRIPT_DIR}/lib/env-defaults.sh"

HARBOR="${HARBOR_HOST:?Set HARBOR_HOST in .env}"
ROOT_CA_DIR="${SVCS_DIR}/services/pki/roots"
ROOT_CA_PEM="${ROOT_CA_DIR}/root-ca.pem"
ROOT_CA_KEY="${ROOT_CA_DIR}/root-ca-key.pem"

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

# --- Prerequisites check ---
check_prereqs() {
  local missing=()
  command -v helm   &>/dev/null || missing+=("helm")
  command -v kubectl &>/dev/null || missing+=("kubectl")
  command -v jq     &>/dev/null || missing+=("jq")
  command -v python3 &>/dev/null || missing+=("python3")
  command -v curl   &>/dev/null || missing+=("curl")

  if (( ${#missing[@]} > 0 )); then
    die "Missing required tools: ${missing[*]}"
  fi

  python3 -c "import yaml" 2>/dev/null || die "python3 PyYAML module not installed (pip3 install pyyaml)"
}

# ============================================================
# Phase 1: Push Helm Charts to Harbor
# ============================================================
push_charts() {
  echo ""
  echo -e "${BOLD}${BLUE}Phase 1: Push Helm Charts to Harbor${NC}"
  echo -e "${BOLD}${BLUE}------------------------------------------------------------${NC}"

  # Verify Harbor is reachable
  if ! curl -sk -o /dev/null -w "%{http_code}" "https://${HARBOR}/api/v2.0/health" | grep -q "200"; then
    die "Harbor not reachable at https://${HARBOR}"
  fi
  log_ok "Harbor reachable at ${HARBOR}"

  # Delegate to push-charts.sh
  local push_script="${SCRIPT_DIR}/push-charts.sh"
  [[ -x "${push_script}" ]] || die "push-charts.sh not found at ${push_script}"

  log_info "Pushing upstream Helm charts to oci://${HARBOR}/helm/ ..."
  bash "${push_script}"
  log_ok "All Helm charts pushed to Harbor"
}

# ============================================================
# Phase 2: Seed Root CA on Downstream Cluster
# ============================================================
get_downstream_kubeconfig() {
  log_info "Fetching downstream cluster kubeconfig from Rancher..."

  # Find the cluster ID for the target cluster
  local cluster_id
  cluster_id=$(curl -sk \
    -H "Authorization: Bearer ${RANCHER_TOKEN}" \
    "${RANCHER_URL}/v1/provisioning.cattle.io.clusters/${FLEET_NAMESPACE}/${FLEET_TARGET_CLUSTER}" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',{}).get('clusterName',''))" 2>/dev/null)

  [[ -n "${cluster_id}" ]] || die "Could not find cluster ID for ${FLEET_TARGET_CLUSTER}"
  log_info "Cluster ID: ${cluster_id}"

  # Generate kubeconfig via Rancher API
  DOWNSTREAM_KUBECONFIG=$(mktemp /tmp/downstream-kubeconfig.XXXXXX)
  curl -sk \
    -H "Authorization: Bearer ${RANCHER_TOKEN}" \
    -X POST \
    "${RANCHER_URL}/v3/clusters/${cluster_id}?action=generateKubeconfig" | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['config'])" > "${DOWNSTREAM_KUBECONFIG}"

  # Verify it works
  if ! kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" get nodes &>/dev/null; then
    rm -f "${DOWNSTREAM_KUBECONFIG}"
    die "Failed to connect to downstream cluster with generated kubeconfig"
  fi

  log_ok "Downstream kubeconfig ready ($(kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" get nodes --no-headers | wc -l) nodes)"
}

seed_root_ca() {
  echo ""
  echo -e "${BOLD}${BLUE}Phase 2: Seed Root CA on Downstream Cluster${NC}"
  echo -e "${BOLD}${BLUE}------------------------------------------------------------${NC}"

  # Verify Root CA files exist
  [[ -f "${ROOT_CA_PEM}" ]] || die "Root CA not found at ${ROOT_CA_PEM}"
  [[ -f "${ROOT_CA_KEY}" ]] || die "Root CA key not found at ${ROOT_CA_KEY}"
  log_ok "Root CA files found"

  get_downstream_kubeconfig

  # Create cert-manager namespace if needed
  kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" create namespace cert-manager --dry-run=client -o yaml | \
    kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" apply -f - 2>/dev/null
  log_ok "cert-manager namespace ready"

  # Create/update the root-ca Secret
  local existing
  existing=$(kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" -n cert-manager get secret root-ca --no-headers 2>/dev/null || echo "")

  if [[ -n "${existing}" ]]; then
    log_warn "root-ca Secret already exists — updating"
  fi

  kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" -n cert-manager create secret tls root-ca \
    --cert="${ROOT_CA_PEM}" \
    --key="${ROOT_CA_KEY}" \
    --dry-run=client -o yaml | \
    kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" apply -f -
  log_ok "Root CA secret seeded in cert-manager namespace"

  # Create kube-system vault-root-ca ConfigMap (needed by traefik-auth, hubble-auth, keycloak-config, gitlab runners)
  kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" -n kube-system create configmap vault-root-ca \
    --from-file=ca.crt="${ROOT_CA_PEM}" \
    --dry-run=client -o yaml | \
    kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" apply -f -
  log_ok "vault-root-ca ConfigMap seeded in kube-system"

  # Create vault namespace (cert-only — root CA key stays offline)
  kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" create namespace vault --dry-run=client -o yaml | \
    kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" apply -f - 2>/dev/null
  log_ok "vault namespace ready"

  # Create monitoring namespace (needed early — Keycloak creates ServiceMonitor/PrometheusRule here)
  kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" create namespace monitoring --dry-run=client -o yaml | \
    kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" apply -f - 2>/dev/null
  log_ok "monitoring namespace ready"

  # --- Cluster Autoscaler Secrets ---
  log_info "Seeding cluster-autoscaler secrets..."
  kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" create namespace cluster-autoscaler --dry-run=client -o yaml | \
    kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" apply -f - 2>/dev/null

  # cloud-config: Rancher API connection for autoscaler
  local cloud_config_tmp
  cloud_config_tmp=$(mktemp)
  cat > "${cloud_config_tmp}" <<CLOUDCFG
url: ${RANCHER_URL}
token: ${RANCHER_TOKEN}
clusterName: ${FLEET_TARGET_CLUSTER}
clusterNamespace: ${FLEET_NAMESPACE}
CLOUDCFG
  kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" -n cluster-autoscaler \
    create secret generic cluster-autoscaler-cloud-config \
    --from-file=cloud-config="${cloud_config_tmp}" \
    --dry-run=client -o yaml | \
    kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" apply -f -
  rm -f "${cloud_config_tmp}"
  log_ok "cluster-autoscaler-cloud-config seeded"

  # ca-cert: Combined CA bundle for trusting Rancher TLS
  local ca_bundle_tmp
  ca_bundle_tmp=$(mktemp)
  # Fetch Rancher server cert chain
  local rancher_host
  rancher_host=$(echo "${RANCHER_URL}" | sed 's|https://||; s|/.*||')
  openssl s_client -connect "${rancher_host}:443" -servername "${rancher_host}" \
    -showcerts </dev/null 2>/dev/null | \
    sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > "${ca_bundle_tmp}"
  # Append root CA
  cat "${ROOT_CA_PEM}" >> "${ca_bundle_tmp}"
  # Append system CAs if available
  for sys_ca in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do
    if [[ -f "${sys_ca}" ]]; then
      cat "${sys_ca}" >> "${ca_bundle_tmp}"
      break
    fi
  done
  kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" -n cluster-autoscaler \
    create secret generic cluster-autoscaler-ca-cert \
    --from-file=ca.crt="${ca_bundle_tmp}" \
    --dry-run=client -o yaml | \
    kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" apply --server-side --force-conflicts -f -
  rm -f "${ca_bundle_tmp}"
  log_ok "cluster-autoscaler-ca-cert seeded"

  # --- Traefik HelmChartConfig ---
  # Apply RKE2 system Traefik overrides (dashboard, Gateway API, CA trust, SSH port)
  # This resource is owned by RKE2's addon manager and cannot be managed via Fleet.
  log_info "Applying Traefik HelmChartConfig..."
  local traefik_hcc="${SVCS_DIR}/services/traefik-dashboard/helmchartconfig.yaml"
  if [[ -f "${traefik_hcc}" ]]; then
    # Replace placeholder LB IP with actual value
    sed "s/CHANGEME_TRAEFIK_LB_IP/${TRAEFIK_LB_IP}/g" "${traefik_hcc}" | \
      kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" apply --server-side --force-conflicts -f -
    log_ok "Traefik HelmChartConfig applied (dashboard + Gateway API + CA trust)"
  else
    log_warn "Traefik HelmChartConfig not found at ${traefik_hcc} — skipping"
  fi

  # Cleanup
  rm -f "${DOWNSTREAM_KUBECONFIG}"
}

# ============================================================
# Phase 3: Push Raw Manifest Bundles to Harbor
# ============================================================
push_bundles() {
  echo ""
  echo -e "${BOLD}${BLUE}Phase 3: Push Raw Manifest Bundles to Harbor${NC}"
  echo -e "${BOLD}${BLUE}------------------------------------------------------------${NC}"

  local push_script="${SCRIPT_DIR}/push-bundles.sh"
  [[ -x "${push_script}" ]] || die "push-bundles.sh not found at ${push_script}"

  log_info "Packaging and pushing raw manifest bundles to oci://${HARBOR}/fleet/ ..."
  bash "${push_script}"
  log_ok "All raw manifest bundles pushed to Harbor"
}

# ============================================================
# Phase 4: Deploy Fleet HelmOps
# ============================================================
deploy_helmops() {
  echo ""
  echo -e "${BOLD}${BLUE}Phase 4: Deploy Fleet HelmOps${NC}"
  echo -e "${BOLD}${BLUE}------------------------------------------------------------${NC}"

  local deploy_script="${SCRIPT_DIR}/deploy-fleet-helmops.sh"
  [[ -x "${deploy_script}" ]] || die "deploy-fleet-helmops.sh not found at ${deploy_script}"

  local args=()
  [[ "${DRY_RUN}" == true ]] && args+=("--dry-run")
  [[ -n "${SINGLE_GROUP}" ]] && args+=("--group" "${SINGLE_GROUP}")

  log_info "Creating Fleet HelmOp CRs on Rancher..."
  bash "${deploy_script}" "${args[@]+"${args[@]}"}"
}

# ============================================================
# Phase 5: Sign Vault Intermediate CSR (offline)
# ============================================================
sign_intermediate_csr() {
  echo ""
  echo -e "${BOLD}${BLUE}Phase 5: Sign Vault Intermediate CSR${NC}"
  echo -e "${BOLD}${BLUE}------------------------------------------------------------${NC}"

  [[ -f "${ROOT_CA_PEM}" ]] || die "Root CA cert not found at ${ROOT_CA_PEM}"
  [[ -f "${ROOT_CA_KEY}" ]] || die "Root CA key not found at ${ROOT_CA_KEY}"

  get_downstream_kubeconfig

  # Wait for vault-init to create the CSR secret
  log_info "Waiting for vault-init to generate intermediate CSR..."
  local csr_found=false
  for _i in $(seq 1 60); do
    if kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" -n vault get secret vault-intermediate-csr &>/dev/null; then
      csr_found=true
      break
    fi
    sleep 10
  done
  [[ "${csr_found}" == true ]] || die "vault-intermediate-csr Secret not found after 10 minutes. Check vault-init Job logs."

  # Wait for vault-0 pod to be Running and Ready before exec
  log_info "Waiting for vault-0 to be ready..."
  local vault_ready=false
  for _i in $(seq 1 60); do
    if kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" -n vault get pod vault-0 &>/dev/null && \
       kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" -n vault wait pod/vault-0 --for=condition=Ready --timeout=10s &>/dev/null; then
      vault_ready=true
      break
    fi
    sleep 5
  done
  [[ "${vault_ready}" == true ]] || die "vault-0 pod not ready after 5 minutes"
  log_ok "vault-0 is ready"

  # Check if already signed (intermediate CA cert exists in Vault)
  local vault_root_token
  vault_root_token=$(kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" -n vault get secret vault-init-keys \
    -o jsonpath='{.data.init\.json}' | base64 -d | sed -n 's/.*"root_token" *: *"\([^"]*\)".*/\1/p')

  local int_check
  int_check=$(kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" -n vault exec vault-0 -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${vault_root_token}" \
    vault read -format=json pki_int/ca/pem 2>/dev/null || true)

  if echo "${int_check}" | grep -q "BEGIN CERTIFICATE"; then
    log_ok "Intermediate CA already signed — skipping"
    rm -f "${DOWNSTREAM_KUBECONFIG}"
    return 0
  fi

  # Read the CSR
  local csr_pem
  csr_pem=$(kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" -n vault get secret vault-intermediate-csr \
    -o jsonpath='{.data.csr\.pem}' | base64 -d)
  [[ -n "${csr_pem}" ]] || die "CSR is empty"
  log_ok "Intermediate CSR retrieved from cluster"

  # Sign locally with openssl (root CA key stays on this machine)
  local csr_tmp signed_tmp ext_tmp
  csr_tmp=$(mktemp)
  signed_tmp=$(mktemp)
  ext_tmp=$(mktemp)

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
    -CA "${ROOT_CA_PEM}" \
    -CAkey "${ROOT_CA_KEY}" \
    -CAcreateserial \
    -out "${signed_tmp}" \
    -sha256 \
    -extfile "${ext_tmp}" \
    -extensions v3_intermediate_ca

  # Verify chain
  openssl verify -CAfile "${ROOT_CA_PEM}" "${signed_tmp}" || die "Chain verification failed"
  log_ok "Intermediate CA signed and verified"

  # Build full chain (intermediate + root)
  local chain_tmp
  chain_tmp=$(mktemp)
  cat "${signed_tmp}" "${ROOT_CA_PEM}" > "${chain_tmp}"

  # Import signed chain into Vault pki_int/
  log_info "Importing signed intermediate chain into Vault..."
  local chain_b64
  chain_b64=$(base64 -w0 "${chain_tmp}")
  kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" -n vault exec vault-0 -- \
    sh -c "echo '${chain_b64}' | base64 -d > /tmp/intermediate-chain.pem"
  kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" -n vault exec vault-0 -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${vault_root_token}" \
    vault write pki_int/intermediate/set-signed certificate=@/tmp/intermediate-chain.pem

  # Configure the signing role
  local domain="${DOMAIN}"
  local domain_dot="${domain//./-dot-}"
  kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" -n vault exec vault-0 -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${vault_root_token}" \
    vault write "pki_int/roles/${domain_dot}" \
      allowed_domains="${domain},cluster.local" \
      allow_subdomains=true \
      allow_bare_domains=true \
      max_ttl=720h \
      require_cn=false \
      generate_lease=true
  log_ok "PKI signing role configured: pki_int/roles/${domain_dot}"

  # Save signed cert to services/pki/intermediates/vault/ for reference
  local int_dir="${SVCS_DIR}/services/pki/intermediates/vault"
  mkdir -p "${int_dir}"
  cp "${signed_tmp}" "${int_dir}/vault-int-ca.pem"
  cp "${chain_tmp}" "${int_dir}/ca-chain.pem"
  log_ok "Signed intermediate saved to ${int_dir}/"

  # Cleanup
  rm -f "${csr_tmp}" "${signed_tmp}" "${ext_tmp}" "${chain_tmp}" "${DOWNSTREAM_KUBECONFIG}"
  log_ok "Vault intermediate CA signed and imported — root CA key stays offline"
}

# Phase 5.5 removed — most service secrets are now self-generated via ESO
# PushSecret + Password generators in each service bundle.
# See: */manifests/push-secret.yaml in each service directory.
#
# Manual secrets (vendor-provided, cannot be auto-generated) are seeded below.

# ============================================================
# Phase 6: Seed manual secrets into Vault
# ============================================================
seed_manual_secrets() {
  echo -e "${BOLD}${BLUE}Phase 6: Seed Manual Secrets${NC}"
  echo -e "${BOLD}${BLUE}------------------------------------------------------------${NC}"

  get_downstream_kubeconfig

  # Get Vault root token
  local root_token
  root_token=$(kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" get secret vault-init-keys -n vault \
    -o jsonpath='{.data.init\.json}' | base64 -d | python3 -c "import json,sys; print(json.load(sys.stdin)['root_token'])")
  [[ -n "${root_token}" ]] || die "Could not retrieve Vault root token"

  vexec() {
    kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" exec -n vault vault-0 -- env \
      VAULT_ADDR=http://127.0.0.1:8200 \
      VAULT_TOKEN="${root_token}" \
      vault "$@"
  }

  # GitLab license activation code (or empty placeholder so ESO doesn't fail)
  local existing
  existing=$(vexec kv get -field=activation-code kv/services/gitlab 2>/dev/null || true)
  if [[ -n "${existing}" ]]; then
    log_warn "GitLab license already in Vault — skipping"
  elif [[ -n "${GITLAB_LICENSE:-}" ]]; then
    vexec kv put kv/services/gitlab activation-code="${GITLAB_LICENSE}"
    log_ok "GitLab license seeded in Vault at services/gitlab"
  else
    vexec kv put kv/services/gitlab activation-code=""
    log_warn "No GITLAB_LICENSE in .env — seeded empty placeholder (Community Edition)"
  fi

  # Harvester kubeconfig (used by golden-image-builder runner to orchestrate builds)
  if [[ -n "${HARVESTER_KUBECONFIG_PATH:-}" && -f "${HARVESTER_KUBECONFIG_PATH}" ]]; then
    local existing_kubeconfig
    existing_kubeconfig=$(vexec kv get -field=kubeconfig kv/services/ci/harvester-kubeconfig 2>/dev/null || true)
    if [[ -n "${existing_kubeconfig}" ]]; then
      log_warn "Harvester kubeconfig already in Vault — skipping"
    else
      local kubeconfig_content
      kubeconfig_content=$(cat "${HARVESTER_KUBECONFIG_PATH}")
      vexec kv put kv/services/ci/harvester-kubeconfig \
        kubeconfig="${kubeconfig_content}"
      log_ok "Harvester kubeconfig seeded in Vault at services/ci/harvester-kubeconfig"
    fi
  else
    log_warn "HARVESTER_KUBECONFIG_PATH not set or file missing — skipping kubeconfig seeding"
  fi
}

# ============================================================
# Main
# ============================================================
DRY_RUN=false
DELETE_MODE=false
STATUS_MODE=false
WATCH_MODE=false
WATCH_INTERVAL=""
SKIP_CHARTS=false
SKIP_BUNDLES=false
SINGLE_GROUP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=true; shift ;;
    --delete)        DELETE_MODE=true; shift ;;
    --status)        STATUS_MODE=true; shift ;;
    --watch)         WATCH_MODE=true; STATUS_MODE=true; shift ;;
    --interval)      WATCH_INTERVAL="$2"; shift 2 ;;
    --skip-push)     SKIP_CHARTS=true; SKIP_BUNDLES=true; shift ;;
    --skip-charts)   SKIP_CHARTS=true; shift ;;
    --skip-bundles)  SKIP_BUNDLES=true; shift ;;
    --group)         SINGLE_GROUP="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --skip-push        Skip pushing both charts and bundles to Harbor"
      echo "  --skip-charts      Skip pushing Helm charts to Harbor"
      echo "  --skip-bundles     Skip pushing raw manifest bundles to Harbor"
      echo "  --dry-run          Show HelmOp CRs without applying"
      echo "  --delete           Remove all Fleet HelmOps from cluster"
      echo "  --status           Show Fleet deployment status"
      echo "  --watch            Live-watch status until all bundles converge (implies --status)"
      echo "  --interval <sec>   Refresh interval for --watch (default: 10)"
      echo "  --group <group>    Deploy only one group (e.g., 00-operators)"
      echo "  -h, --help         Show this help"
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

echo -e "${BOLD}${BLUE}============================================================${NC}"
echo -e "${BOLD}${BLUE}  Fleet GitOps — Unified Deployment${NC}"
echo -e "${BOLD}${BLUE}============================================================${NC}"

check_prereqs
load_config

# Status / Delete modes delegate directly
if [[ "${STATUS_MODE}" == true ]]; then
  status_args=("--status")
  [[ "${WATCH_MODE}" == true ]] && status_args+=("--watch")
  [[ -n "${WATCH_INTERVAL}" ]] && status_args+=("--interval" "${WATCH_INTERVAL}")
  bash "${SCRIPT_DIR}/deploy-fleet-helmops.sh" "${status_args[@]}"
  exit 0
fi

if [[ "${DELETE_MODE}" == true ]]; then
  bash "${SCRIPT_DIR}/deploy-fleet-helmops.sh" --delete
  exit 0
fi

# Full deployment pipeline
if [[ "${SKIP_CHARTS}" != true ]]; then
  push_charts
else
  log_info "Skipping Helm chart push (--skip-charts)"
fi

if [[ "${SKIP_BUNDLES}" != true ]]; then
  push_bundles
else
  log_info "Skipping bundle push (--skip-bundles)"
fi

seed_root_ca
deploy_helmops
sign_intermediate_csr
seed_manual_secrets

echo ""
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo -e "${BOLD}${GREEN}  Deployment Complete${NC}"
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo ""
echo -e "Monitor progress:  ${BOLD}$0 --status${NC}  (or ${BOLD}$0 --watch${NC} for live updates)"
echo -e "Rancher UI:        Continuous Delivery → App Bundles"
echo ""
