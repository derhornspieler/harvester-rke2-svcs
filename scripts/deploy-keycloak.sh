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

# Keycloak defaults
KC_REALM="${KC_REALM:-platform}"
export KC_REALM

# CNPG operator Helm chart
HELM_CHART_CNPG="${HELM_CHART_CNPG:-cnpg/cloudnative-pg}"
HELM_REPO_CNPG="${HELM_REPO_CNPG:-https://cloudnative-pg.github.io/charts}"

# Vault init file
VAULT_INIT_FILE="${VAULT_INIT_FILE:-${REPO_ROOT}/vault-init.json}"

# CLI Parsing
PHASE_FROM=1
PHASE_TO=8
VALIDATE_ONLY=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Deploy Keycloak identity provider with CNPG PostgreSQL, OAuth2-proxy, and monitoring.

Options:
  --phase N       Run only phase N
  --from N        Start from phase N (default: 1)
  --to N          Stop after phase N (default: 8)
  --validate      Health check all components (no changes)
  -h, --help      Show this help

Phases:
  1  Shared Data Svc     CNPG operator (skip if exists)
  2  Namespaces + Vault  Create namespaces, seed Vault, create SecretStores
  3  ESO + MinIO         Apply ExternalSecrets, deploy MinIO
  4  PostgreSQL CNPG     HA cluster (3 instances), scheduled backup
  5  Keycloak            RBAC, services, deployment, health check
  6  Gateway + HPA       Gateway, HTTPRoute, HPA, TLS verification
  7  OAuth2-proxy        External secrets, deployments, middleware CRDs
  8  Monitoring + Verify Dashboards, alerts, ServiceMonitors
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)     PHASE_FROM="$2"; PHASE_TO="$2"; shift 2 ;;
    --from)      PHASE_FROM="$2"; shift 2 ;;
    --to)        PHASE_TO="$2"; shift 2 ;;
    --validate)  VALIDATE_ONLY=true; shift ;;
    -h|--help)   usage ;;
    *)           die "Unknown option: $1" ;;
  esac
done

# Validation mode
if [[ "$VALIDATE_ONLY" == "true" ]]; then
  start_phase "Validation: Keycloak Health Check"

  log_info "Checking keycloak deployment..."
  if kubectl -n keycloak get deployment keycloak \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null; then
    echo " replica(s) ready"
  else
    log_error "keycloak deployment not found"
  fi

  log_info "Checking CNPG PostgreSQL pods..."
  if kubectl -n database get pods -l "cnpg.io/cluster=keycloak-pg,role=primary" \
    --no-headers 2>/dev/null | grep -q "Running"; then
    log_ok "CNPG keycloak-pg primary is running"
  else
    log_error "CNPG keycloak-pg primary not found or not running"
  fi

  log_info "Checking TLS secret..."
  if kubectl -n keycloak get secret "keycloak-${DOMAIN_DASHED}-tls" &>/dev/null; then
    log_ok "TLS secret keycloak-${DOMAIN_DASHED}-tls exists"
  else
    log_warn "TLS secret keycloak-${DOMAIN_DASHED}-tls not found"
  fi

  end_phase "Validation: Keycloak Health Check"
  exit 0
fi

# Phase 1: Shared Data Services (CNPG operator + MinIO)
if [[ $PHASE_FROM -le 1 && $PHASE_TO -ge 1 ]]; then
  start_phase "Phase 1: Shared Data Services"

  # Install CNPG operator (skip only if the controller is already running)
  # CRDs may persist after teardown, so check the actual deployment not the CRD
  if ! kubectl -n cnpg-system get deployment cnpg-controller-manager &>/dev/null; then
    # Pre-apply CRDs with --server-side to avoid "too long" annotation errors
    # Vendored CRDs ensure airgap compatibility and prevent Helm install failures
    log_info "Pre-applying CNPG CRDs (server-side)..."
    kubectl apply --server-side --force-conflicts \
      -f "${SCRIPT_DIR}/manifests/cnpg-crds-v0.27.1.yaml"

    log_info "Installing CloudNativePG operator..."
    helm_repo_add cnpg "$HELM_REPO_CNPG"
    helm_install_if_needed cnpg "$HELM_CHART_CNPG" cnpg-system \
      --version "${HELM_VERSION_CNPG:-0.27.0}" \
      --set monitoring.podMonitorEnabled=true \
      --set nodeSelector.workload-type=database \
      --set crds.create=false \
      --wait --timeout 5m
    # Deployment name varies by chart version: cnpg-cloudnative-pg or cnpg-controller-manager
    _cnpg_deploy=$(kubectl -n cnpg-system get deployment -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    wait_for_deployment cnpg-system "${_cnpg_deploy:-cnpg-cloudnative-pg}" 300s

    # Apply HPA and PDB for the CNPG operator
    log_info "Applying CNPG operator HPA and PDB..."
    kubectl apply -f "${REPO_ROOT}/services/cnpg-operator/hpa.yaml"
    kubectl apply -f "${REPO_ROOT}/services/cnpg-operator/pdb.yaml"
  else
    log_info "CNPG operator already running, skipping install"
  fi

  end_phase "Phase 1: Shared Data Services"
fi

# Phase 2: Namespaces + Vault Secrets + SecretStores
if [[ $PHASE_FROM -le 2 && $PHASE_TO -ge 2 ]]; then
  start_phase "Phase 2: Namespaces + Vault Secrets"

  # Create namespaces
  kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f "${REPO_ROOT}/services/keycloak/namespace.yaml"
  kubectl create namespace database --dry-run=client -o yaml | kubectl apply -f -

  # Create vault-root-ca ConfigMap in keycloak namespace (CA trust for OIDC, TLS)
  ROOT_CA_CERT="${ROOT_CA_CERT:-${REPO_ROOT}/services/pki/roots/root-ca.pem}"
  if [[ -f "$ROOT_CA_CERT" ]]; then
    log_info "Creating vault-root-ca ConfigMap in keycloak..."
    kubectl create configmap vault-root-ca \
      --namespace=keycloak \
      --from-file=ca.crt="$ROOT_CA_CERT" \
      --dry-run=client -o yaml | kubectl apply -f -
  else
    log_warn "Root CA cert not found at ${ROOT_CA_CERT} — vault-root-ca ConfigMap not created in keycloak"
  fi

  # Seed Vault KV secrets
  [[ -f "$VAULT_INIT_FILE" ]] || die "Vault init file not found: ${VAULT_INIT_FILE}"
  root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")

  # Read existing credentials from Vault or generate new ones (idempotent)
  log_info "Reading/generating credentials (Vault-first, no regeneration on re-run)..."

  MINIO_ROOT_USER="${MINIO_ROOT_USER:-$(vault_get_or_generate "$root_token" \
    "kv/services/minio/root-credentials" "root-user" "echo minio-admin")}"
  MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-$(vault_get_or_generate "$root_token" \
    "kv/services/minio/root-credentials" "root-password" "openssl rand -base64 24")}"

  log_info "Storing MinIO credentials in Vault..."
  vault_exec "$root_token" kv put kv/services/minio/root-credentials \
    root-user="$MINIO_ROOT_USER" \
    root-password="$MINIO_ROOT_PASSWORD"

  # Keycloak admin credentials (single break-glass admin)
  KC_ADMIN_USER="${KC_ADMIN_USER:-$(vault_get_or_generate "$root_token" \
    "kv/services/keycloak/admin-secret" "KC_BOOTSTRAP_ADMIN_USERNAME" "echo admin-breakglass")}"
  KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-$(vault_get_or_generate "$root_token" \
    "kv/services/keycloak/admin-secret" "KC_BOOTSTRAP_ADMIN_PASSWORD" "openssl rand -base64 24")}"
  KC_ADMIN_CLIENT_ID="${KC_ADMIN_CLIENT_ID:-$(vault_get_or_generate "$root_token" \
    "kv/services/keycloak/admin-secret" "KC_BOOTSTRAP_ADMIN_CLIENT_ID" "echo temp-admin-svc")}"
  KC_ADMIN_CLIENT_SECRET="${KC_ADMIN_CLIENT_SECRET:-$(vault_get_or_generate "$root_token" \
    "kv/services/keycloak/admin-secret" "KC_BOOTSTRAP_ADMIN_CLIENT_SECRET" "openssl rand -hex 32")}"

  vault_exec "$root_token" kv put kv/services/keycloak/admin-secret \
    KC_BOOTSTRAP_ADMIN_USERNAME="$KC_ADMIN_USER" \
    KC_BOOTSTRAP_ADMIN_PASSWORD="$KC_ADMIN_PASSWORD" \
    KC_BOOTSTRAP_ADMIN_CLIENT_ID="$KC_ADMIN_CLIENT_ID" \
    KC_BOOTSTRAP_ADMIN_CLIENT_SECRET="$KC_ADMIN_CLIENT_SECRET"

  # Keycloak PostgreSQL credentials
  PG_KC_USER="${PG_KC_USER:-$(vault_get_or_generate "$root_token" \
    "kv/services/database/keycloak-pg" "username" "echo keycloak")}"
  PG_KC_PASSWORD="${PG_KC_PASSWORD:-$(vault_get_or_generate "$root_token" \
    "kv/services/database/keycloak-pg" "password" "openssl rand -base64 24")}"

  vault_exec "$root_token" kv put kv/services/keycloak/postgres-secret \
    POSTGRES_USER="$PG_KC_USER" \
    POSTGRES_PASSWORD="$PG_KC_PASSWORD"

  vault_exec "$root_token" kv put kv/services/database/keycloak-pg \
    username="$PG_KC_USER" \
    password="$PG_KC_PASSWORD"

  # Create Vault K8s auth roles and policies for each namespace
  for ns in minio keycloak database; do
    log_info "Creating Vault K8s auth role eso-${ns}..."
    vault_exec "$root_token" write "auth/kubernetes/role/eso-${ns}" \
      bound_service_account_names=eso-secrets \
      "bound_service_account_namespaces=${ns}" \
      "policies=eso-${ns}" \
      ttl=1h

    # Write policy via kubectl exec with stdin
    kubectl exec -i -n vault vault-0 -- env \
      VAULT_ADDR=http://127.0.0.1:8200 \
      VAULT_TOKEN="$root_token" \
      vault policy write "eso-${ns}" - <<POLICY
path "kv/data/services/${ns}" {
  capabilities = ["read"]
}
path "kv/data/services/${ns}/*" {
  capabilities = ["read"]
}
path "kv/metadata/services/${ns}" {
  capabilities = ["read", "list"]
}
path "kv/metadata/services/${ns}/*" {
  capabilities = ["read", "list"]
}
POLICY

    # Create service account and SecretStore in each namespace
    kubectl create serviceaccount eso-secrets -n "$ns" \
      --dry-run=client -o yaml | kubectl apply -f -

    kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: ${ns}
spec:
  provider:
    vault:
      server: http://vault.vault.svc.cluster.local:8200
      path: kv
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: eso-${ns}
          serviceAccountRef:
            name: eso-secrets
EOF
  done

  end_phase "Phase 2: Namespaces + Vault Secrets"
fi

# Phase 3: ESO ExternalSecrets + MinIO
if [[ $PHASE_FROM -le 3 && $PHASE_TO -ge 3 ]]; then
  start_phase "Phase 3: ESO ExternalSecrets + MinIO"

  # Apply ExternalSecrets for all components
  kubectl apply -f "${REPO_ROOT}/services/harbor/minio/external-secret.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/keycloak/external-secret.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/postgres/external-secret.yaml"

  # Wait for secrets to sync
  log_info "Waiting for ExternalSecrets to sync..."
  sleep 10
  for secret in minio-root-credentials:minio keycloak-admin-secret:keycloak \
    keycloak-postgres-secret:keycloak keycloak-pg-credentials:database; do
    local_name="${secret%%:*}"
    local_ns="${secret##*:}"
    if kubectl -n "$local_ns" get secret "$local_name" &>/dev/null; then
      log_ok "Secret ${local_name} synced in ${local_ns}"
    else
      log_warn "Secret ${local_name} not yet synced in ${local_ns} (ESO may still be reconciling)"
    fi
  done

  # Deploy MinIO (shared object storage for CNPG backups)
  if ! kubectl -n minio get deployment minio &>/dev/null; then
    log_info "Deploying MinIO..."
    kubectl apply -f "${REPO_ROOT}/services/harbor/minio/pvc.yaml"
    kubectl apply -f "${REPO_ROOT}/services/harbor/minio/deployment.yaml"
    kubectl apply -f "${REPO_ROOT}/services/harbor/minio/service.yaml"
    wait_for_deployment minio minio 300s

    # Create buckets needed by CNPG
    log_info "Creating MinIO buckets for CNPG backups..."
    kube_apply_subst "${REPO_ROOT}/services/harbor/minio/job-create-buckets.yaml"
  else
    log_info "MinIO already deployed, skipping"
  fi

  end_phase "Phase 3: ESO ExternalSecrets + MinIO"
fi

# Phase 4: PostgreSQL CNPG
if [[ $PHASE_FROM -le 4 && $PHASE_TO -ge 4 ]]; then
  start_phase "Phase 4: PostgreSQL CNPG"
  kube_apply_subst "${REPO_ROOT}/services/keycloak/postgres/keycloak-pg-cluster.yaml"

  log_info "Waiting for CNPG primary to be ready (this may take several minutes)..."
  wait_for_pods_ready database "cnpg.io/cluster=keycloak-pg,role=primary" 600

  kubectl apply -f "${REPO_ROOT}/services/keycloak/postgres/keycloak-pg-scheduled-backup.yaml"
  # Apply VolumeAutoscaler for keycloak-pg PVCs
  log_info "Applying VolumeAutoscaler for keycloak-pg..."
  kubectl apply -f "${REPO_ROOT}/services/keycloak/volume-autoscalers.yaml"

  end_phase "Phase 4: PostgreSQL CNPG"
fi

# Phase 5: Keycloak
if [[ $PHASE_FROM -le 5 && $PHASE_TO -ge 5 ]]; then
  start_phase "Phase 5: Keycloak"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/keycloak/rbac.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/keycloak/service.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/keycloak/service-headless.yaml"
  kube_apply_subst "${REPO_ROOT}/services/keycloak/keycloak/deployment.yaml"
  wait_for_deployment keycloak keycloak 600s

  # Health check (Keycloak image doesn't have curl; use wget or kubectl port-forward)
  log_info "Verifying Keycloak health..."
  kubectl exec -n keycloak deploy/keycloak -- \
    sh -c 'exec 3<>/dev/tcp/127.0.0.1/8080 && echo -e "GET /health/ready HTTP/1.1\r\nHost: localhost\r\n\r\n" >&3 && head -1 <&3' 2>/dev/null | grep -q "200" \
    || log_warn "Keycloak health endpoint not yet responding (may need a moment)"

  end_phase "Phase 5: Keycloak"
fi

# Phase 6: Gateway + HTTPRoute + HPA
if [[ $PHASE_FROM -le 6 && $PHASE_TO -ge 6 ]]; then
  start_phase "Phase 6: Gateway + HTTPRoute + HPA"
  kube_apply_subst "${REPO_ROOT}/services/keycloak/gateway.yaml"
  kube_apply_subst "${REPO_ROOT}/services/keycloak/httproute.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/keycloak/hpa.yaml"
  wait_for_tls_secret keycloak "keycloak-${DOMAIN_DASHED}-tls" 300
  end_phase "Phase 6: Gateway + HTTPRoute + HPA"
fi

# Phase 7: OAuth2-proxy (requires monitoring namespace from Bundle 3 + setup-keycloak.sh)
if [[ $PHASE_FROM -le 7 && $PHASE_TO -ge 7 ]]; then
  start_phase "Phase 7: OAuth2-proxy"

  log_info "Applying OAuth2-proxy instances..."
  log_warn "NOTE: Run setup-keycloak.sh BEFORE this phase to create OIDC clients"

  # Ensure target namespaces exist (monitoring for prom/alertmanager, kube-system for hubble)
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

  # vault-root-ca ConfigMap — OAuth2-proxies mount this for OIDC TLS verification
  ROOT_CA_CERT="${ROOT_CA_CERT:-${REPO_ROOT}/services/pki/roots/root-ca.pem}"
  if [[ -f "$ROOT_CA_CERT" ]]; then
    for ns in monitoring kube-system; do
      kubectl create configmap vault-root-ca --namespace="$ns" \
        --from-file=ca.crt="$ROOT_CA_CERT" \
        --dry-run=client -o yaml | kubectl apply -f -
    done
  else
    log_warn "Root CA cert not found at ${ROOT_CA_CERT} — OAuth2-proxy OIDC TLS may fail"
  fi

  # External secrets for OIDC client credentials
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/external-secret-prometheus.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/external-secret-alertmanager.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/external-secret-hubble.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/external-secret-grafana.yaml"

  # OAuth2-proxy deployments
  kube_apply_subst "${REPO_ROOT}/services/keycloak/oauth2-proxy/prometheus.yaml"
  kube_apply_subst "${REPO_ROOT}/services/keycloak/oauth2-proxy/alertmanager.yaml"
  kube_apply_subst "${REPO_ROOT}/services/keycloak/oauth2-proxy/hubble.yaml"

  # Middleware CRDs
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/middleware-prometheus.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/middleware-alertmanager.yaml"
  kubectl apply -f "${REPO_ROOT}/services/keycloak/oauth2-proxy/middleware-hubble.yaml"

  end_phase "Phase 7: OAuth2-proxy"
fi

# Phase 8: Monitoring + NetworkPolicies
if [[ $PHASE_FROM -le 8 && $PHASE_TO -ge 8 ]]; then
  start_phase "Phase 8: Monitoring + NetworkPolicies"

  if kubectl get ns monitoring &>/dev/null && kubectl get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
    kubectl apply -k "${REPO_ROOT}/services/keycloak/monitoring/"
  else
    log_warn "Monitoring namespace or CRDs not found — skipping ServiceMonitors/alerts (deploy after Bundle 3)"
  fi

  end_phase "Phase 8: Monitoring + NetworkPolicies"
fi

log_ok "Keycloak deployment complete"
