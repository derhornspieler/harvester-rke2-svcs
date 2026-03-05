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
source "${SCRIPT_DIR}/utils/basic-auth.sh"

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

# Helm chart sources
HELM_CHART_GITLAB="${HELM_CHART_GITLAB:-gitlab/gitlab}"
HELM_REPO_GITLAB="${HELM_REPO_GITLAB:-https://charts.gitlab.io}"
HELM_CHART_RUNNER="${HELM_CHART_RUNNER:-gitlab/gitlab-runner}"

# GitLab service directory
GITLAB_DIR="${REPO_ROOT}/services/gitlab"

# CLI Parsing
PHASE_FROM=1
PHASE_TO=9
VALIDATE_ONLY=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Deploy GitLab with CNPG PostgreSQL, OpsTree Redis Sentinel, Gateway API, Runners, and monitoring.

Options:
  --phase N       Run only phase N
  --from N        Start from phase N (default: 1)
  --to N          Stop after phase N (default: 9)
  --validate      Health check all components (no changes)
  -h, --help      Show this help

Phases:
  1  Namespaces           Create gitlab, gitlab-runners, ensure database namespace
  2  ESO                  SecretStores + ExternalSecrets (gitaly, praefect, redis, oidc, root, harbor-push)
  3  PostgreSQL CNPG      HA cluster, praefect user/db creation, scheduled backup
  4  Redis                OpsTree RedisReplication + RedisSentinel
  5  Gateway + TCPRoute   Gateway (HTTPS + SSH), TCPRoute for SSH, wait for TLS
  6  GitLab Helm          Helm install, wait for migrations (30m), wait for deployments
  7  Runners              Shared, security, and group runner Helm installs
  8  VolumeAutoscalers    Apply volume-autoscalers.yaml
  9  Monitoring + Verify  Apply monitoring kustomize, verify HTTPS + SSH
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
  start_phase "Validation: GitLab Health Check"

  log_info "Checking gitlab-webservice deployment..."
  if kubectl -n gitlab get deployment -l "app=webservice" \
    -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null; then
    echo " replica(s) ready"
  else
    log_error "gitlab-webservice not found"
  fi

  log_info "Checking CNPG PostgreSQL pods..."
  if kubectl -n database get pods -l "cnpg.io/cluster=gitlab-postgresql,role=primary" \
    --no-headers 2>/dev/null | grep -q "Running"; then
    log_ok "CNPG gitlab-postgresql primary is running"
  else
    log_error "CNPG gitlab-postgresql primary not found or not running"
  fi

  log_info "Checking Redis pods..."
  local_redis_count=$(kubectl -n gitlab get pods -l "app=gitlab-redis" \
    --no-headers 2>/dev/null | grep -c "Running" || true)
  if [[ "$local_redis_count" -gt 0 ]]; then
    log_ok "Redis: ${local_redis_count} pod(s) running"
  else
    log_error "Redis pods not found"
  fi

  log_info "Checking TLS secrets..."
  for tls_secret in "gitlab-${DOMAIN_DASHED}-tls" "kas-${DOMAIN_DASHED}-tls"; do
    if kubectl -n gitlab get secret "$tls_secret" &>/dev/null; then
      log_ok "TLS secret ${tls_secret} exists"
    else
      log_warn "TLS secret ${tls_secret} not found"
    fi
  done

  log_info "Checking SSH connectivity..."
  if kubectl -n gitlab get tcproute gitlab-ssh &>/dev/null; then
    log_ok "TCPRoute gitlab-ssh exists"
  else
    log_warn "TCPRoute gitlab-ssh not found"
  fi

  end_phase "Validation: GitLab Health Check"
  exit 0
fi

# Phase 1: Namespaces
if [[ $PHASE_FROM -le 1 && $PHASE_TO -ge 1 ]]; then
  start_phase "Phase 1: Namespaces"
  kubectl apply -f "${GITLAB_DIR}/namespace.yaml"
  kubectl apply -f "${GITLAB_DIR}/runners/namespace.yaml"
  kubectl create namespace database --dry-run=client -o yaml | kubectl apply -f -
  end_phase "Phase 1: Namespaces"
fi

# Phase 2: ESO SecretStores + ExternalSecrets
if [[ $PHASE_FROM -le 2 && $PHASE_TO -ge 2 ]]; then
  start_phase "Phase 2: ESO SecretStores + ExternalSecrets"
  [[ -f "$VAULT_INIT_FILE" ]] || die "Vault init file not found: ${VAULT_INIT_FILE}"
  root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")

  # Create Vault K8s auth roles and policies for gitlab and gitlab-runners namespaces
  for ns in gitlab gitlab-runners; do
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

  # gitlab-runners policy also needs access to ci/ path for harbor-push credentials
  log_info "Extending gitlab-runners Vault policy for ci/ path..."
  vault_exec "$root_token" policy write "eso-gitlab-runners" - <<POLICY
path "kv/data/services/gitlab-runners/*" {
  capabilities = ["read"]
}
path "kv/metadata/services/gitlab-runners/*" {
  capabilities = ["read", "list"]
}
path "kv/data/ci/*" {
  capabilities = ["read"]
}
path "kv/metadata/ci/*" {
  capabilities = ["read", "list"]
}
POLICY

  # Apply all ExternalSecrets in gitlab namespace
  kubectl apply -f "${GITLAB_DIR}/gitaly/external-secret.yaml"
  kubectl apply -f "${GITLAB_DIR}/praefect/external-secret-dbsecret.yaml"
  kubectl apply -f "${GITLAB_DIR}/praefect/external-secret-token.yaml"
  kubectl apply -f "${GITLAB_DIR}/redis/external-secret.yaml"
  kubectl apply -f "${GITLAB_DIR}/oidc/external-secret.yaml"
  kubectl apply -f "${GITLAB_DIR}/root/external-secret.yaml"

  # Apply ExternalSecrets in gitlab-runners namespace
  kubectl apply -f "${GITLAB_DIR}/runners/external-secret-harbor-push.yaml"

  # Wait for secrets to sync
  log_info "Waiting for ExternalSecrets to sync..."
  sleep 10
  for secret in gitlab-gitaly-secret:gitlab \
    gitlab-praefect-dbsecret:gitlab \
    gitlab-praefect-secret:gitlab \
    gitlab-redis-credentials:gitlab \
    gitlab-oidc-secret:gitlab \
    gitlab-gitlab-initial-root-password:gitlab \
    harbor-ci-push:gitlab-runners; do
    local_name="${secret%%:*}"
    local_ns="${secret##*:}"
    if kubectl -n "$local_ns" get secret "$local_name" &>/dev/null; then
      log_ok "Secret ${local_name} synced in ${local_ns}"
    else
      log_warn "Secret ${local_name} not yet synced in ${local_ns} (ESO may still be reconciling)"
    fi
  done

  end_phase "Phase 2: ESO SecretStores + ExternalSecrets"
fi

# Phase 3: PostgreSQL CNPG
if [[ $PHASE_FROM -le 3 && $PHASE_TO -ge 3 ]]; then
  start_phase "Phase 3: PostgreSQL CNPG"
  kube_apply_subst "${GITLAB_DIR}/cloudnativepg-cluster.yaml"

  log_info "Waiting for CNPG primary to be ready (this may take several minutes)..."
  wait_for_pods_ready database "cnpg.io/cluster=gitlab-postgresql,role=primary" 600

  # Set praefect user password from the ESO-synced secret
  log_info "Configuring praefect database user..."
  praefect_password=$(kubectl -n gitlab get secret gitlab-praefect-dbsecret \
    -o jsonpath='{.data.secret}' 2>/dev/null | base64 -d) || true
  if [[ -n "${praefect_password:-}" ]]; then
    # Use the CNPG primary pod to ALTER the praefect user password
    primary_pod=$(kubectl -n database get pods \
      -l "cnpg.io/cluster=gitlab-postgresql,role=primary" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "${primary_pod:-}" ]]; then
      log_info "Setting praefect user password via ${primary_pod}..."
      if kubectl -n database exec "$primary_pod" -- \
        psql -U postgres -d gitlabhq_production \
        -c "ALTER USER praefect WITH PASSWORD '${praefect_password}';" 2>/dev/null; then
        log_ok "Praefect user password configured"
      else
        log_warn "Failed to set praefect password (may require superuser access or manual setup)"
      fi
    else
      log_warn "CNPG primary pod not found, skipping praefect password setup"
    fi
  else
    log_warn "Praefect dbsecret not available, skipping password setup"
  fi

  kubectl apply -f "${GITLAB_DIR}/cloudnativepg-scheduled-backup.yaml"
  end_phase "Phase 3: PostgreSQL CNPG"
fi

# Phase 4: Redis (OpsTree Operator)
if [[ $PHASE_FROM -le 4 && $PHASE_TO -ge 4 ]]; then
  start_phase "Phase 4: Redis (OpsTree Sentinel HA)"
  kubectl apply -f "${GITLAB_DIR}/redis/external-secret.yaml"
  kubectl apply -f "${GITLAB_DIR}/redis/replication.yaml"
  kubectl apply -f "${GITLAB_DIR}/redis/sentinel.yaml"
  wait_for_pods_ready gitlab "app=gitlab-redis" 300
  end_phase "Phase 4: Redis (OpsTree Sentinel HA)"
fi

# Phase 5: Gateway + TCPRoute
if [[ $PHASE_FROM -le 5 && $PHASE_TO -ge 5 ]]; then
  start_phase "Phase 5: Gateway + TCPRoute"
  kube_apply_subst "${GITLAB_DIR}/gateway.yaml"
  kubectl apply -f "${GITLAB_DIR}/tcproute-ssh.yaml"
  wait_for_tls_secret gitlab "gitlab-${DOMAIN_DASHED}-tls" 300
  end_phase "Phase 5: Gateway + TCPRoute"
fi

# Phase 6: GitLab Helm Install
if [[ $PHASE_FROM -le 6 && $PHASE_TO -ge 6 ]]; then
  start_phase "Phase 6: GitLab Helm Install"

  # Add GitLab Helm repo (non-OCI)
  helm_repo_add gitlab "$HELM_REPO_GITLAB"

  # Substitute CHANGEME tokens in values file before passing to Helm
  _subst_changeme < "${GITLAB_DIR}/values-rke2-prod.yaml" > /tmp/gitlab-values.yaml
  helm_install_if_needed gitlab "$HELM_CHART_GITLAB" gitlab \
    -f /tmp/gitlab-values.yaml \
    --timeout 30m
  rm -f /tmp/gitlab-values.yaml

  # Wait for database migrations job (can take 20-30 min on first install)
  log_info "Waiting for GitLab migrations job to complete (timeout: 1800s)..."
  migrations_timeout=1800
  migrations_interval=15
  migrations_elapsed=0
  migrations_done=false
  while [[ $migrations_elapsed -lt $migrations_timeout ]]; do
    # Find the latest migrations job
    job_name=$(kubectl -n gitlab get jobs -l "app=migrations" \
      -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)
    if [[ -n "${job_name:-}" ]]; then
      job_status=$(kubectl -n gitlab get job "$job_name" \
        -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)
      if [[ "$job_status" == "True" ]]; then
        log_ok "Migrations job ${job_name} completed"
        migrations_done=true
        break
      fi
      job_failed=$(kubectl -n gitlab get job "$job_name" \
        -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)
      if [[ "$job_failed" == "True" ]]; then
        die "Migrations job ${job_name} failed — check logs: kubectl -n gitlab logs job/${job_name}"
      fi
    fi
    sleep "$migrations_interval"
    migrations_elapsed=$((migrations_elapsed + migrations_interval))
    if (( migrations_elapsed % 60 == 0 )); then
      log_info "  ...still waiting for migrations (${migrations_elapsed}s / ${migrations_timeout}s)"
    fi
  done
  if [[ "$migrations_done" != "true" ]]; then
    die "Migrations job did not complete within ${migrations_timeout}s"
  fi

  # Wait for core GitLab deployments
  log_info "Waiting for GitLab deployments to become available..."
  wait_for_deployment gitlab gitlab-webservice-default 600s
  wait_for_deployment gitlab gitlab-sidekiq-all-in-1-v2 600s
  wait_for_deployment gitlab gitlab-gitlab-shell 300s
  wait_for_deployment gitlab gitlab-kas 300s

  end_phase "Phase 6: GitLab Helm Install"
fi

# Phase 7: GitLab Runners
if [[ $PHASE_FROM -le 7 && $PHASE_TO -ge 7 ]]; then
  start_phase "Phase 7: GitLab Runners"

  # Apply runner RBAC (ServiceAccount, Role, RoleBinding)
  kubectl apply -k "${GITLAB_DIR}/runners/"

  # Shared runner
  log_info "Installing shared runner..."
  _subst_changeme < "${GITLAB_DIR}/runners/shared-runner-values.yaml" > /tmp/shared-runner-values.yaml
  helm_install_if_needed gitlab-runner-shared "$HELM_CHART_RUNNER" gitlab-runners \
    -f /tmp/shared-runner-values.yaml \
    --wait --timeout 5m
  rm -f /tmp/shared-runner-values.yaml

  # Security runner
  log_info "Installing security runner..."
  _subst_changeme < "${GITLAB_DIR}/runners/security-runner-values.yaml" > /tmp/security-runner-values.yaml
  helm_install_if_needed gitlab-runner-security "$HELM_CHART_RUNNER" gitlab-runners \
    -f /tmp/security-runner-values.yaml \
    --wait --timeout 5m
  rm -f /tmp/security-runner-values.yaml

  # Group runner (platform-services)
  log_info "Installing group runner..."
  _subst_changeme < "${GITLAB_DIR}/runners/group-runner-values.yaml" > /tmp/group-runner-values.yaml
  helm_install_if_needed gitlab-runner-group "$HELM_CHART_RUNNER" gitlab-runners \
    -f /tmp/group-runner-values.yaml \
    --wait --timeout 5m
  rm -f /tmp/group-runner-values.yaml

  end_phase "Phase 7: GitLab Runners"
fi

# Phase 8: VolumeAutoscalers
if [[ $PHASE_FROM -le 8 && $PHASE_TO -ge 8 ]]; then
  start_phase "Phase 8: VolumeAutoscalers"
  kubectl apply -f "${GITLAB_DIR}/volume-autoscalers.yaml"
  end_phase "Phase 8: VolumeAutoscalers"
fi

# Phase 9: Monitoring + Verify
if [[ $PHASE_FROM -le 9 && $PHASE_TO -ge 9 ]]; then
  start_phase "Phase 9: Monitoring + Verify"
  kubectl apply -k "${GITLAB_DIR}/monitoring/"

  # Verify HTTPS endpoint
  log_info "Verifying GitLab HTTPS endpoint..."
  gitlab_url="https://gitlab.${DOMAIN}"
  if curl -sfk --max-time 10 "${gitlab_url}/-/health" >/dev/null 2>&1; then
    log_ok "GitLab HTTPS health check passed: ${gitlab_url}/-/health"
  else
    log_warn "GitLab HTTPS health check did not respond (may still be starting)"
  fi

  # Verify SSH via TCPRoute
  log_info "Verifying GitLab SSH connectivity..."
  if kubectl -n gitlab get tcproute gitlab-ssh &>/dev/null; then
    log_ok "TCPRoute gitlab-ssh is configured"
  else
    log_warn "TCPRoute gitlab-ssh not found"
  fi

  end_phase "Phase 9: Monitoring + Verify"
fi

log_ok "GitLab deployment complete"
