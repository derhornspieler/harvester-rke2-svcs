#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source utility modules
source "${SCRIPT_DIR}/utils/log.sh"
source "${SCRIPT_DIR}/utils/helm.sh"
source "${SCRIPT_DIR}/utils/wait.sh"
source "${SCRIPT_DIR}/utils/vault.sh"
source "${SCRIPT_DIR}/utils/subst.sh"

# Load environment
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
fi

# Domain defaults
DOMAIN="${DOMAIN:?DOMAIN must be set}"
DOMAIN_DASHED="${DOMAIN_DASHED:-$(echo "$DOMAIN" | tr '.' '-')}"
DOMAIN_DOT="${DOMAIN_DOT:-${DOMAIN//./-dot-}}"
export DOMAIN DOMAIN_DASHED DOMAIN_DOT

# Vault init file
VAULT_INIT_FILE="${VAULT_INIT_FILE:-${REPO_ROOT}/vault-init.json}"

# Organization name (used in Vault intermediate CA CN)
ORG="${ORG:-My Organization}"

# Root CA paths
ROOT_CA_CERT="${ROOT_CA_CERT:-${REPO_ROOT}/services/pki/roots/root-ca.pem}"
ROOT_CA_KEY="${ROOT_CA_KEY:-}"

# Helm chart sources (override with oci:// paths for Harbor or private registries)
HELM_CHART_CERTMANAGER="${HELM_CHART_CERTMANAGER:-jetstack/cert-manager}"
HELM_CHART_VAULT="${HELM_CHART_VAULT:-hashicorp/vault}"
HELM_CHART_ESO="${HELM_CHART_ESO:-external-secrets/external-secrets}"
HELM_REPO_CERTMANAGER="${HELM_REPO_CERTMANAGER:-https://charts.jetstack.io}"
HELM_REPO_VAULT="${HELM_REPO_VAULT:-https://helm.releases.hashicorp.com}"
HELM_REPO_ESO="${HELM_REPO_ESO:-https://charts.external-secrets.io}"

# CLI Parsing
PHASE_FROM=1
PHASE_TO=7
UNSEAL_ONLY=false
VALIDATE_ONLY=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Deploy PKI & Secrets bundle (Vault + cert-manager + ESO).

Options:
  --phase N       Run only phase N
  --from N        Start from phase N (default: 1)
  --to N          Stop after phase N (default: 7)
  --unseal-only   Just unseal Vault (skip everything else)
  --validate      Health check all components (no changes)
  -h, --help      Show this help

Phases:
  1  cert-manager    Helm install (CRDs, gateway-shim)
  2  Vault           Helm install -> init -> unseal -> Raft join
  3  PKI             Import Root CA -> intermediate CSR -> sign -> import chain
  4  Vault K8s Auth  Enable K8s auth, create roles
  5  cert-manager    Apply RBAC, ClusterIssuer, verify TLS
  6  ESO             Helm install, verify controller
  7  Kustomize       Apply monitoring, gateways, httproutes
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)     PHASE_FROM="$2"; PHASE_TO="$2"; shift 2 ;;
    --from)      PHASE_FROM="$2"; shift 2 ;;
    --to)        PHASE_TO="$2"; shift 2 ;;
    --unseal-only) UNSEAL_ONLY=true; shift ;;
    --validate)  VALIDATE_ONLY=true; shift ;;
    -h|--help)   usage ;;
    *)           die "Unknown option: $1" ;;
  esac
done

# Validation mode
if [[ "$VALIDATE_ONLY" == "true" ]]; then
  start_phase "Validation: Health Check"
  log_info "Checking Vault..."
  kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null \
    | jq '{initialized, sealed, cluster_name}' || log_error "Vault unreachable"
  log_info "Checking cert-manager..."
  if kubectl get clusterissuer vault-issuer -o jsonpath='{.status.conditions[0].status}' 2>/dev/null; then
    echo ""
  else
    log_error "ClusterIssuer not found"
  fi
  log_info "Checking ESO..."
  if kubectl -n external-secrets get deployment external-secrets \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null; then
    echo " replica(s) ready"
  else
    log_error "ESO not found"
  fi
  end_phase "Validation: Health Check"
  exit 0
fi

# Unseal-only mode
if [[ "$UNSEAL_ONLY" == "true" ]]; then
  start_phase "Unseal Vault"
  [[ -f "$VAULT_INIT_FILE" ]] || die "Vault init file not found: ${VAULT_INIT_FILE}"
  vault_unseal_all "$VAULT_INIT_FILE"
  end_phase "Unseal Vault"
  exit 0
fi

# Phase 1: cert-manager
if [[ $PHASE_FROM -le 1 && $PHASE_TO -ge 1 ]]; then
  start_phase "Phase 1: cert-manager"
  helm_repo_add jetstack "$HELM_REPO_CERTMANAGER"
  helm_install_if_needed cert-manager "$HELM_CHART_CERTMANAGER" cert-manager \
    --version v1.19.4 \
    --set crds.enabled=true \
    --set config.apiVersion=controller.config.cert-manager.io/v1alpha1 \
    --set config.kind=ControllerConfiguration \
    --set config.enableGatewayAPI=true \
    --set nodeSelector.workload-type=general \
    --wait --timeout 5m
  wait_for_deployment cert-manager cert-manager 300s
  end_phase "Phase 1: cert-manager"
fi

# Phase 2: Vault
if [[ $PHASE_FROM -le 2 && $PHASE_TO -ge 2 ]]; then
  start_phase "Phase 2: Vault"
  helm_repo_add hashicorp "$HELM_REPO_VAULT"
  helm_install_if_needed vault "$HELM_CHART_VAULT" vault \
    --version 0.32.0 \
    -f "${REPO_ROOT}/services/vault/vault-values.yaml" \
    --timeout 5m
  # Vault pods won't be Ready until initialized+unsealed; wait for Running first
  wait_for_pods_running vault "app.kubernetes.io/name=vault" 3 300

  if ! vault_is_initialized; then
    vault_init "$VAULT_INIT_FILE"
    log_warn "IMPORTANT: Back up ${VAULT_INIT_FILE} securely. It contains unseal keys and root token."
  else
    log_info "Vault already initialized"
  fi

  if vault_is_sealed; then
    [[ -f "$VAULT_INIT_FILE" ]] || die "Vault is sealed but init file not found: ${VAULT_INIT_FILE}"
    vault_unseal_replica 0 "$VAULT_INIT_FILE"
  else
    log_info "Vault-0 already unsealed"
  fi

  # Join replicas to Raft cluster and unseal them
  for i in 1 2; do
    joined=$(kubectl exec -n vault "vault-${i}" -- vault status -format=json 2>/dev/null \
      | jq -r '.storage_type' || echo "")
    if [[ "$joined" != "raft" ]]; then
      log_info "Joining vault-${i} to Raft cluster..."
      kubectl exec -n vault "vault-${i}" -- vault operator raft join http://vault-0.vault-internal:8200
    fi
    if kubectl exec -n vault "vault-${i}" -- vault status -format=json 2>/dev/null \
      | jq -e '.sealed == true' >/dev/null 2>&1; then
      vault_unseal_replica "$i" "$VAULT_INIT_FILE"
    else
      log_info "vault-${i} already unsealed"
    fi
  done

  # Now wait for all pods to pass readiness probes
  wait_for_pods_ready vault "app.kubernetes.io/name=vault" 300
  end_phase "Phase 2: Vault"
fi

# Phase 3: PKI
if [[ $PHASE_FROM -le 3 && $PHASE_TO -ge 3 ]]; then
  start_phase "Phase 3: PKI Setup"
  [[ -f "$ROOT_CA_CERT" ]] || die "Root CA cert not found: ${ROOT_CA_CERT}"
  [[ -n "$ROOT_CA_KEY" && -f "$ROOT_CA_KEY" ]] || die "Root CA key path must be set (ROOT_CA_KEY)"

  root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")

  # Enable PKI secrets engine for Root CA
  vault_exec "$root_token" secrets enable -path=pki pki 2>/dev/null || log_info "pki engine already enabled"
  vault_exec "$root_token" secrets tune -max-lease-ttl=87600h pki

  # Import Root CA certificate
  log_info "Importing Root CA certificate into Vault pki/"
  kubectl cp "$ROOT_CA_CERT" vault/vault-0:/tmp/root-ca.pem
  vault_exec "$root_token" write pki/config/ca pem_bundle=@/tmp/root-ca.pem

  # Enable intermediate PKI
  vault_exec "$root_token" secrets enable -path=pki_int pki 2>/dev/null || log_info "pki_int engine already enabled"
  vault_exec "$root_token" secrets tune -max-lease-ttl=43800h pki_int

  # Generate intermediate CSR inside Vault
  log_info "Generating intermediate CSR inside Vault..."
  vault_exec "$root_token" write -format=json \
    pki_int/intermediate/generate/internal \
    common_name="${ORG} Vault Intermediate CA" \
    organization="${ORG}" \
    key_type=rsa \
    key_bits=4096 \
    | jq -r '.data.csr' > /tmp/vault-intermediate.csr

  # Sign the intermediate CSR with the offline Root CA key
  log_info "Signing intermediate CSR with Root CA..."
  openssl x509 -req -days 5475 \
    -in /tmp/vault-intermediate.csr \
    -CA "$ROOT_CA_CERT" \
    -CAkey "$ROOT_CA_KEY" \
    -CAcreateserial \
    -extfile <(printf "basicConstraints=critical,CA:true,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign") \
    -out /tmp/vault-intermediate.pem

  # Create certificate chain
  cat /tmp/vault-intermediate.pem "$ROOT_CA_CERT" > /tmp/vault-intermediate-chain.pem

  # Import signed chain into Vault
  log_info "Importing signed intermediate chain into Vault..."
  kubectl cp /tmp/vault-intermediate-chain.pem vault/vault-0:/tmp/intermediate-chain.pem
  vault_exec "$root_token" write pki_int/intermediate/set-signed \
    certificate=@/tmp/intermediate-chain.pem

  # Configure signing role
  vault_exec "$root_token" write "pki_int/roles/${DOMAIN_DOT}" \
    allowed_domains="${DOMAIN}" \
    allowed_domains="cluster.local" \
    allow_subdomains=true \
    max_ttl=720h \
    generate_lease=true

  # Clean up temp files
  rm -f /tmp/vault-intermediate.csr /tmp/vault-intermediate.pem /tmp/vault-intermediate-chain.pem
  log_ok "PKI hierarchy established: Root CA -> Vault Intermediate (pathlen:0)"
  end_phase "Phase 3: PKI Setup"
fi

# Phase 4: Vault Kubernetes Auth
if [[ $PHASE_FROM -le 4 && $PHASE_TO -ge 4 ]]; then
  start_phase "Phase 4: Vault Kubernetes Auth"
  root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")

  vault_exec "$root_token" auth enable kubernetes 2>/dev/null || log_info "kubernetes auth already enabled"
  vault_exec "$root_token" write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc:443"

  # cert-manager issuer role
  vault_exec "$root_token" write auth/kubernetes/role/cert-manager-issuer \
    bound_service_account_names=vault-issuer \
    bound_service_account_namespaces=cert-manager \
    policies=cert-manager-pki \
    ttl=1h

  # cert-manager PKI policy
  vault_exec "$root_token" policy write cert-manager-pki - <<POLICY
path "pki_int/sign/${DOMAIN_DOT}" {
  capabilities = ["create", "update"]
}
path "pki_int/issue/${DOMAIN_DOT}" {
  capabilities = ["create"]
}
POLICY

  # Enable KV v2 for application secrets
  vault_exec "$root_token" secrets enable -version=2 -path=kv kv 2>/dev/null || log_info "kv engine already enabled"
  log_ok "Vault K8s auth configured with cert-manager and KV roles"
  end_phase "Phase 4: Vault Kubernetes Auth"
fi

# Phase 5: cert-manager Integration
if [[ $PHASE_FROM -le 5 && $PHASE_TO -ge 5 ]]; then
  start_phase "Phase 5: cert-manager Integration"
  kubectl apply -f "${REPO_ROOT}/services/cert-manager/rbac.yaml"
  kube_apply_subst "${REPO_ROOT}/services/cert-manager/cluster-issuer.yaml"
  wait_for_clusterissuer vault-issuer 300
  end_phase "Phase 5: cert-manager Integration"
fi

# Phase 6: External Secrets Operator
if [[ $PHASE_FROM -le 6 && $PHASE_TO -ge 6 ]]; then
  start_phase "Phase 6: External Secrets Operator"
  helm_repo_add external-secrets "$HELM_REPO_ESO"
  helm_install_if_needed external-secrets "$HELM_CHART_ESO" external-secrets \
    --version 2.0.1 \
    --set installCRDs=true \
    --set serviceMonitor.enabled=true \
    --set resources.requests.cpu=100m \
    --set resources.requests.memory=128Mi \
    --set resources.limits.cpu=500m \
    --set resources.limits.memory=512Mi \
    --set nodeSelector.workload-type=general \
    --wait --timeout 5m
  wait_for_deployment external-secrets external-secrets 300s
  log_ok "ESO controller is running"
  end_phase "Phase 6: External Secrets Operator"
fi

# Phase 7: Kustomize Overlays
if [[ $PHASE_FROM -le 7 && $PHASE_TO -ge 7 ]]; then
  start_phase "Phase 7: Kustomize Overlays"
  kube_apply_subst "${REPO_ROOT}/services/vault/gateway.yaml"
  kube_apply_subst "${REPO_ROOT}/services/vault/httproute.yaml"
  kubectl apply -k "${REPO_ROOT}/services/vault/monitoring/"
  kubectl apply -k "${REPO_ROOT}/services/cert-manager/monitoring/"
  kubectl apply -k "${REPO_ROOT}/services/external-secrets/monitoring/"
  wait_for_tls_secret vault "vault-${DOMAIN_DASHED}-tls" 300
  log_ok "All Kustomize overlays applied"
  end_phase "Phase 7: Kustomize Overlays"
fi

log_ok "PKI & Secrets bundle deployment complete"
