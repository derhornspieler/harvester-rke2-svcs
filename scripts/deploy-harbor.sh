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

# Organization name (already in env from PKI bundle)
ORG="${ORG:-My Organization}"

# Helm chart source (Harbor uses OCI by default)
HELM_CHART_HARBOR="${HELM_CHART_HARBOR:-oci://registry-1.docker.io/goharbor/harbor-helm}"

# CLI Parsing
PHASE_FROM=1
PHASE_TO=8
VALIDATE_ONLY=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Deploy Harbor container registry with MinIO, CNPG PostgreSQL, and Valkey backends.

Options:
  --phase N       Run only phase N
  --from N        Start from phase N (default: 1)
  --to N          Stop after phase N (default: 8)
  --validate      Health check all components (no changes)
  -h, --help      Show this help

Phases:
  1  Namespaces           Create harbor, minio, database namespaces
  2  ESO SecretStores     Vault K8s auth roles + apply ExternalSecrets
  3  MinIO                PVC, deployment, service, bucket creation job
  4  PostgreSQL CNPG      HA cluster (3 instances), scheduled backup
  5  Valkey Sentinel      RedisReplication + RedisSentinel
  6  Harbor Helm          Helm install with substituted values
  7  Ingress + HPAs       Gateway, HTTPRoute, autoscaling
  8  Monitoring + Verify  Dashboards, alerts, ServiceMonitors
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
  start_phase "Validation: Harbor Health Check"

  log_info "Checking harbor-core deployment..."
  if kubectl -n harbor get deployment harbor-core \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null; then
    echo " replica(s) ready"
  else
    log_error "harbor-core not found"
  fi

  log_info "Checking MinIO deployment..."
  if kubectl -n minio get deployment minio \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null; then
    echo " replica(s) ready"
  else
    log_error "MinIO not found"
  fi

  log_info "Checking CNPG PostgreSQL pods..."
  if kubectl -n database get pods -l "cnpg.io/cluster=harbor-pg,role=primary" \
    --no-headers 2>/dev/null | grep -q "Running"; then
    log_ok "CNPG primary is running"
  else
    log_error "CNPG primary not found or not running"
  fi

  log_info "Checking Valkey pods..."
  local_valkey_count=$(kubectl -n harbor get pods -l "app=harbor-redis" \
    --no-headers 2>/dev/null | grep -c "Running" || true)
  if [[ "$local_valkey_count" -gt 0 ]]; then
    log_ok "Valkey: ${local_valkey_count} pod(s) running"
  else
    log_error "Valkey pods not found"
  fi

  log_info "Checking TLS secret..."
  if kubectl -n harbor get secret "harbor-${DOMAIN_DASHED}-tls" &>/dev/null; then
    log_ok "TLS secret harbor-${DOMAIN_DASHED}-tls exists"
  else
    log_warn "TLS secret harbor-${DOMAIN_DASHED}-tls not found"
  fi

  end_phase "Validation: Harbor Health Check"
  exit 0
fi

# Phase 1: Namespaces
if [[ $PHASE_FROM -le 1 && $PHASE_TO -ge 1 ]]; then
  start_phase "Phase 1: Namespaces"
  kubectl apply -f "${REPO_ROOT}/services/harbor/namespace.yaml"
  kubectl apply -f "${REPO_ROOT}/services/harbor/minio/namespace.yaml"
  kubectl create namespace database --dry-run=client -o yaml | kubectl apply -f -
  end_phase "Phase 1: Namespaces"
fi

# Phase 2: ESO SecretStores
if [[ $PHASE_FROM -le 2 && $PHASE_TO -ge 2 ]]; then
  start_phase "Phase 2: ESO SecretStores"
  [[ -f "$VAULT_INIT_FILE" ]] || die "Vault init file not found: ${VAULT_INIT_FILE}"
  root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")

  # Create Vault K8s auth roles and policies for each namespace
  for ns in minio database harbor; do
    log_info "Creating Vault K8s auth role eso-${ns}..."
    vault_exec "$root_token" write "auth/kubernetes/role/eso-${ns}" \
      bound_service_account_names=eso-secrets \
      "bound_service_account_namespaces=${ns}" \
      "policies=eso-${ns}" \
      ttl=1h

    vault_exec "$root_token" policy write "eso-${ns}" - <<POLICY
path "kv/data/services/${ns}/*" {
  capabilities = ["read"]
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

  # Apply external secrets for all sub-components
  kubectl apply -f "${REPO_ROOT}/services/harbor/minio/external-secret.yaml"
  kubectl apply -f "${REPO_ROOT}/services/harbor/postgres/external-secret.yaml"
  kubectl apply -f "${REPO_ROOT}/services/harbor/valkey/external-secret.yaml"

  # Wait for secrets to sync
  log_info "Waiting for ExternalSecrets to sync..."
  sleep 10
  for secret in minio-root-credentials:minio harbor-pg-credentials:database \
    cnpg-minio-credentials:database harbor-valkey-credentials:harbor; do
    local_name="${secret%%:*}"
    local_ns="${secret##*:}"
    if kubectl -n "$local_ns" get secret "$local_name" &>/dev/null; then
      log_ok "Secret ${local_name} synced in ${local_ns}"
    else
      log_warn "Secret ${local_name} not yet synced in ${local_ns} (ESO may still be reconciling)"
    fi
  done

  end_phase "Phase 2: ESO SecretStores"
fi

# Phase 3: MinIO
if [[ $PHASE_FROM -le 3 && $PHASE_TO -ge 3 ]]; then
  start_phase "Phase 3: MinIO"
  kubectl apply -f "${REPO_ROOT}/services/harbor/minio/pvc.yaml"
  kubectl apply -f "${REPO_ROOT}/services/harbor/minio/deployment.yaml"
  kubectl apply -f "${REPO_ROOT}/services/harbor/minio/service.yaml"
  wait_for_deployment minio minio 300s

  # Run bucket creation job
  log_info "Creating MinIO buckets..."
  kube_apply_subst "${REPO_ROOT}/services/harbor/minio/job-create-buckets.yaml"
  end_phase "Phase 3: MinIO"
fi

# Phase 4: PostgreSQL CNPG
if [[ $PHASE_FROM -le 4 && $PHASE_TO -ge 4 ]]; then
  start_phase "Phase 4: PostgreSQL CNPG"
  kube_apply_subst "${REPO_ROOT}/services/harbor/postgres/harbor-pg-cluster.yaml"

  log_info "Waiting for CNPG primary to be ready (this may take several minutes)..."
  wait_for_pods_ready database "cnpg.io/cluster=harbor-pg,role=primary" 600

  kubectl apply -f "${REPO_ROOT}/services/harbor/postgres/harbor-pg-scheduled-backup.yaml"
  end_phase "Phase 4: PostgreSQL CNPG"
fi

# Phase 5: Valkey Redis Sentinel
if [[ $PHASE_FROM -le 5 && $PHASE_TO -ge 5 ]]; then
  start_phase "Phase 5: Valkey Redis Sentinel"
  kubectl apply -f "${REPO_ROOT}/services/harbor/valkey/replication.yaml"
  kubectl apply -f "${REPO_ROOT}/services/harbor/valkey/sentinel.yaml"
  wait_for_pods_ready harbor "app=harbor-redis" 300
  end_phase "Phase 5: Valkey Redis Sentinel"
fi

# Phase 6: Harbor Helm Install
if [[ $PHASE_FROM -le 6 && $PHASE_TO -ge 6 ]]; then
  start_phase "Phase 6: Harbor Helm Install"

  # Substitute CHANGEME tokens in values file before passing to Helm
  _subst_changeme < "${REPO_ROOT}/services/harbor/harbor-values.yaml" > /tmp/harbor-values.yaml
  helm_install_if_needed harbor "$HELM_CHART_HARBOR" harbor \
    --version 1.18.2 \
    -f /tmp/harbor-values.yaml \
    --wait --timeout 10m
  rm -f /tmp/harbor-values.yaml

  wait_for_deployment harbor harbor-core 300s
  wait_for_deployment harbor harbor-registry 300s
  wait_for_deployment harbor harbor-jobservice 300s
  end_phase "Phase 6: Harbor Helm Install"
fi

# Phase 7: Ingress + HPAs
if [[ $PHASE_FROM -le 7 && $PHASE_TO -ge 7 ]]; then
  start_phase "Phase 7: Ingress + HPAs"
  kube_apply_subst "${REPO_ROOT}/services/harbor/gateway.yaml"
  kube_apply_subst "${REPO_ROOT}/services/harbor/httproute.yaml"
  kubectl apply -f "${REPO_ROOT}/services/harbor/hpa-core.yaml"
  kubectl apply -f "${REPO_ROOT}/services/harbor/hpa-registry.yaml"
  kubectl apply -f "${REPO_ROOT}/services/harbor/hpa-trivy.yaml"
  wait_for_tls_secret harbor "harbor-${DOMAIN_DASHED}-tls" 300
  end_phase "Phase 7: Ingress + HPAs"
fi

# Phase 8: Monitoring + Verify
if [[ $PHASE_FROM -le 8 && $PHASE_TO -ge 8 ]]; then
  start_phase "Phase 8: Monitoring + Verify"
  kubectl apply -k "${REPO_ROOT}/services/harbor/monitoring/"
  end_phase "Phase 8: Monitoring + Verify"
fi

log_ok "Harbor deployment complete"
