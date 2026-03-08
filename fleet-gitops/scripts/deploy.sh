#!/usr/bin/env bash
set -euo pipefail

# deploy.sh — Unified Fleet GitOps deployment to an RKE2 cluster
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
#   - Harbor credentials (helm registry login harbor.aegisgroup.ch)
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

HARBOR="harbor.aegisgroup.ch"
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

  [[ -n "${RANCHER_URL:-}" ]] || die "RANCHER_URL not set (export it or add to ${env_file})"
  [[ -n "${RANCHER_TOKEN:-}" ]] || die "RANCHER_TOKEN not set (export it or add to ${env_file})"
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

  # Find the cluster ID for rke2-prod
  local cluster_id
  cluster_id=$(curl -sk \
    -H "Authorization: Bearer ${RANCHER_TOKEN}" \
    "${RANCHER_URL}/v1/provisioning.cattle.io.clusters/fleet-default/rke2-prod" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',{}).get('clusterName',''))" 2>/dev/null)

  [[ -n "${cluster_id}" ]] || die "Could not find cluster ID for rke2-prod"
  log_info "Cluster ID: ${cluster_id}"

  # Generate kubeconfig via Rancher API
  DOWNSTREAM_KUBECONFIG=$(mktemp /tmp/rke2-prod-kubeconfig.XXXXXX)
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
clusterName: rke2-prod
clusterNamespace: fleet-default
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
  for i in $(seq 1 60); do
    if kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" -n vault get secret vault-intermediate-csr &>/dev/null; then
      csr_found=true
      break
    fi
    sleep 10
  done
  [[ "${csr_found}" == true ]] || die "vault-intermediate-csr Secret not found after 10 minutes. Check vault-init Job logs."

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
  local domain="aegisgroup.ch"
  local domain_dot="${domain//./-dot-}"
  kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" -n vault exec vault-0 -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${vault_root_token}" \
    vault write "pki_int/roles/${domain_dot}" \
      allowed_domains="${domain}" \
      allowed_domains="cluster.local" \
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

# ============================================================
# Phase 5.5: Seed Service Secrets in Vault KV
# ============================================================
seed_service_secrets() {
  echo ""
  echo -e "${BOLD}${BLUE}Phase 5.5: Seed Service Secrets in Vault KV${NC}"
  echo -e "${BOLD}${BLUE}------------------------------------------------------------${NC}"

  get_downstream_kubeconfig

  # Read Vault root token
  local vault_root_token
  vault_root_token=$(kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" -n vault get secret vault-init-keys \
    -o jsonpath='{.data.init\.json}' | base64 -d | sed -n 's/.*"root_token" *: *"\([^"]*\)".*/\1/p')
  [[ -n "${vault_root_token}" ]] || die "Could not read Vault root token from vault-init-keys Secret"
  log_ok "Vault root token retrieved"

  # --- Helper: generate random 32-char alphanumeric password (SIGPIPE-safe) ---
  gen_pass() {
    head -c 256 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 32
  }

  # --- Helper: write-once vault kv put (idempotent) ---
  # Usage: vput <path> key1=val1 key2=val2 ...
  vput() {
    local path="$1"; shift

    # Check if the key already exists
    if kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" -n vault exec vault-0 -- \
      env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${vault_root_token}" \
      vault kv get "${path}" &>/dev/null; then
      log_warn "  ${path} already exists — skipped"
      return 0
    fi

    # Write the secret
    kubectl --kubeconfig="${DOWNSTREAM_KUBECONFIG}" -n vault exec vault-0 -- \
      env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${vault_root_token}" \
      vault kv put "${path}" "$@"
    log_ok "  ${path} seeded"
  }

  log_info "Seeding service secrets in Vault KV (write-once / idempotent)..."

  # Database credentials
  vput kv/services/database/keycloak-pg \
    username=keycloak \
    "password=$(gen_pass)"

  vput kv/services/database/harbor-pg \
    username=harbor \
    "password=$(gen_pass)"

  vput kv/services/database/grafana-pg \
    username=grafana \
    "password=$(gen_pass)"

  # Keycloak
  vput kv/services/keycloak/admin-secret \
    KC_BOOTSTRAP_ADMIN_USERNAME=admin \
    "KC_BOOTSTRAP_ADMIN_PASSWORD=$(gen_pass)" \
    KC_BOOTSTRAP_ADMIN_CLIENT_ID=admin-cli \
    "KC_BOOTSTRAP_ADMIN_CLIENT_SECRET=$(gen_pass)"

  vput kv/services/keycloak/platform-admin \
    username=alice.morgan \
    "password=TestPassword!2026" \
    email=alice.morgan@aegisgroup.ch

  # Harbor
  vput kv/services/harbor/admin-password \
    "password=$(gen_pass)"

  # MinIO
  vput kv/services/minio/credentials \
    MINIO_ROOT_USER=minio-admin \
    "MINIO_ROOT_PASSWORD=$(gen_pass)"

  # Monitoring
  vput kv/services/monitoring/grafana-admin \
    username=admin \
    "password=$(gen_pass)"

  # GitLab
  vput kv/services/gitlab/postgres-password \
    "password=$(gen_pass)"

  vput kv/services/gitlab/minio-storage \
    accesskey=gitlab-minio \
    "secretkey=$(gen_pass)"

  # GitLab Runners
  vput kv/services/gitlab-runners/harbor-ci-push \
    username=ci-push \
    "password=$(gen_pass)"

  log_ok "Service secrets seeding complete"

  # Cleanup
  rm -f "${DOWNSTREAM_KUBECONFIG}"
}

# ============================================================
# Main
# ============================================================
DRY_RUN=false
DELETE_MODE=false
STATUS_MODE=false
SKIP_PUSH=false
SINGLE_GROUP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)     DRY_RUN=true; shift ;;
    --delete)      DELETE_MODE=true; shift ;;
    --status)      STATUS_MODE=true; shift ;;
    --skip-push)   SKIP_PUSH=true; shift ;;
    --group)       SINGLE_GROUP="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --skip-push        Skip pushing charts and bundles to Harbor"
      echo "  --dry-run          Show HelmOp CRs without applying"
      echo "  --delete           Remove all Fleet HelmOps from cluster"
      echo "  --status           Show Fleet deployment status"
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
  bash "${SCRIPT_DIR}/deploy-fleet-helmops.sh" --status
  exit 0
fi

if [[ "${DELETE_MODE}" == true ]]; then
  bash "${SCRIPT_DIR}/deploy-fleet-helmops.sh" --delete
  exit 0
fi

# Full deployment pipeline
if [[ "${SKIP_PUSH}" != true ]]; then
  push_charts
  push_bundles
else
  log_info "Skipping chart/bundle push (--skip-push)"
fi

seed_root_ca
deploy_helmops
sign_intermediate_csr
seed_service_secrets

echo ""
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo -e "${BOLD}${GREEN}  Deployment Complete${NC}"
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo ""
echo -e "Monitor progress:  ${BOLD}$0 --status${NC}"
echo -e "Rancher UI:        Continuous Delivery → App Bundles"
echo ""
