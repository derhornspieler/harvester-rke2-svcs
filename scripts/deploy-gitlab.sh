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

# Temp files for Helm values — single trap cleans all on exit
_gitlab_values=""
_shared_values=""
_security_values=""
_group_values=""
trap 'rm -f "$_gitlab_values" "$_shared_values" "$_security_values" "$_group_values"' EXIT

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

  # Seed Vault KV secrets for GitLab components
  log_info "Seeding Vault KV secrets for GitLab..."

  # Redis password
  GITLAB_REDIS_PASSWORD="${GITLAB_REDIS_PASSWORD:-$(openssl rand -base64 24)}"
  vault_exec "$root_token" kv put kv/services/gitlab/redis \
    password="$GITLAB_REDIS_PASSWORD"
  export GITLAB_REDIS_PASSWORD

  # Gitaly token
  GITLAB_GITALY_TOKEN="${GITLAB_GITALY_TOKEN:-$(openssl rand -hex 32)}"
  vault_exec "$root_token" kv put kv/services/gitlab/gitaly-secret \
    token="$GITLAB_GITALY_TOKEN"

  # Praefect DB secret
  GITLAB_PRAEFECT_DB_PASSWORD="${GITLAB_PRAEFECT_DB_PASSWORD:-$(openssl rand -base64 24)}"
  vault_exec "$root_token" kv put kv/services/gitlab/praefect-dbsecret \
    secret="$GITLAB_PRAEFECT_DB_PASSWORD"

  # Praefect internal token
  GITLAB_PRAEFECT_TOKEN="${GITLAB_PRAEFECT_TOKEN:-$(openssl rand -hex 32)}"
  vault_exec "$root_token" kv put kv/services/gitlab/praefect-secret \
    token="$GITLAB_PRAEFECT_TOKEN"

  # Initial root password
  GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PASSWORD:-$(openssl rand -base64 24)}"
  vault_exec "$root_token" kv put kv/services/gitlab/initial-root-password \
    password="$GITLAB_ROOT_PASSWORD"

  # OIDC provider (placeholder — setup-keycloak.sh will update with real client secret)
  GITLAB_OIDC_CLIENT_SECRET="${GITLAB_OIDC_CLIENT_SECRET:-placeholder-update-after-keycloak}"
  _oidc_provider=$(cat <<OIDCJSON
{"name":"openid_connect","label":"Keycloak","args":{"name":"openid_connect","scope":["openid","profile","email"],"response_type":"code","issuer":"https://keycloak.${DOMAIN}/realms/${KC_REALM:-platform}","discovery":true,"client_auth_method":"query","uid_field":"preferred_username","client_options":{"identifier":"gitlab","secret":"${GITLAB_OIDC_CLIENT_SECRET}","redirect_uri":"https://gitlab.${DOMAIN}/users/auth/openid_connect/callback"}}}
OIDCJSON
  )
  vault_exec "$root_token" kv put kv/services/gitlab/oidc-secret \
    provider="$_oidc_provider"

  # Harbor CI push credentials (robot account for runners)
  HARBOR_CI_USER="${HARBOR_CI_USER:-harbor-ci-push}"
  HARBOR_CI_PASSWORD="${HARBOR_CI_PASSWORD:-placeholder-create-harbor-robot-account}"
  vault_exec "$root_token" kv put kv/ci/harbor-push \
    username="$HARBOR_CI_USER" \
    password="$HARBOR_CI_PASSWORD"

  # CNPG PostgreSQL credentials
  GITLAB_DB_USER="${GITLAB_DB_USER:-gitlab}"
  GITLAB_DB_PASSWORD="${GITLAB_DB_PASSWORD:-$(openssl rand -base64 24)}"
  vault_exec "$root_token" kv put kv/services/database/gitlab-pg \
    username="$GITLAB_DB_USER" \
    password="$GITLAB_DB_PASSWORD"

  # CNPG MinIO backup credentials (reuse MinIO root creds)
  MINIO_ROOT_USER=$(kubectl exec -n vault vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$root_token" \
    vault kv get -field=root-user kv/services/minio/root-credentials 2>/dev/null) || true
  MINIO_ROOT_PASSWORD=$(kubectl exec -n vault vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$root_token" \
    vault kv get -field=root-password kv/services/minio/root-credentials 2>/dev/null) || true
  vault_exec "$root_token" kv put kv/services/database/cnpg-minio-gitlab \
    ACCESS_KEY_ID="${MINIO_ROOT_USER}" \
    ACCESS_SECRET_KEY="${MINIO_ROOT_PASSWORD}"

  # Create Vault K8s auth roles and policies for gitlab and gitlab-runners namespaces
  for ns in gitlab gitlab-runners; do
    log_info "Creating Vault K8s auth role eso-${ns}..."
    vault_exec "$root_token" write "auth/kubernetes/role/eso-${ns}" \
      bound_service_account_names=eso-secrets \
      "bound_service_account_namespaces=${ns}" \
      "policies=eso-${ns}" \
      ttl=1h

    # Write policy via kubectl exec with stdin (vault_exec doesn't support stdin)
    kubectl exec -i -n vault vault-0 -- env \
      VAULT_ADDR=http://127.0.0.1:8200 \
      VAULT_TOKEN="$root_token" \
      vault policy write "eso-${ns}" - <<POLICY
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
  kubectl exec -i -n vault vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 \
    VAULT_TOKEN="$root_token" \
    vault policy write "eso-gitlab-runners" - <<POLICY
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
      # Escape single quotes to prevent SQL injection (defense-in-depth)
      escaped_password="${praefect_password//\'/\'\'}"
      if kubectl -n database exec "$primary_pod" -- \
        psql -U postgres -d gitlabhq_production \
        -c "ALTER USER praefect WITH PASSWORD '${escaped_password}';" 2>/dev/null; then
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

  # Copy CNPG-generated gitlab-postgresql-app secret to gitlab namespace
  # (CNPG creates it in database ns; GitLab chart expects it in gitlab ns)
  log_info "Copying gitlab-postgresql-app secret to gitlab namespace..."
  kubectl -n database get secret gitlab-postgresql-app -o json \
    | jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid,
              .metadata.creationTimestamp, .metadata.managedFields,
              .metadata.ownerReferences, .metadata.annotations)' \
    | kubectl -n gitlab apply -f -

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

  # Create gitlab-root-ca secret (Vault CA chain for OIDC/TLS trust)
  log_info "Creating gitlab-root-ca secret with Vault CA chain..."
  root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")
  root_issuer=$(kubectl exec -n vault vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$root_token" \
    vault list -format=json pki/issuers 2>/dev/null | jq -r '.[0]')
  root_ca=$(kubectl exec -n vault vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$root_token" \
    vault read -field=certificate "pki/issuer/${root_issuer}" 2>/dev/null)
  int_issuer=$(kubectl exec -n vault vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$root_token" \
    vault list -format=json pki_int/issuers 2>/dev/null | jq -r '.[0]')
  int_ca=$(kubectl exec -n vault vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$root_token" \
    vault read -field=certificate "pki_int/issuer/${int_issuer}" 2>/dev/null)
  kubectl -n gitlab create secret generic gitlab-root-ca \
    --from-literal="gitlab.${DOMAIN}.pem=${root_ca}
${int_ca}" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Ensure gitlab-postgresql-app secret exists in gitlab namespace
  if ! kubectl -n gitlab get secret gitlab-postgresql-app &>/dev/null; then
    log_info "Copying gitlab-postgresql-app secret to gitlab namespace..."
    kubectl -n database get secret gitlab-postgresql-app -o json \
      | jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid,
                .metadata.creationTimestamp, .metadata.managedFields,
                .metadata.ownerReferences, .metadata.annotations)' \
      | kubectl -n gitlab apply -f -
  fi

  # Add GitLab Helm repo (non-OCI)
  helm_repo_add gitlab "$HELM_REPO_GITLAB"

  # Substitute CHANGEME tokens in values file before passing to Helm
  _gitlab_values=$(mktemp /tmp/gitlab-values.XXXXXX.yaml)
  _subst_changeme < "${GITLAB_DIR}/values-rke2-prod.yaml" > "$_gitlab_values"
  chmod 600 "$_gitlab_values"
  helm_install_if_needed gitlab "$HELM_CHART_GITLAB" gitlab \
    -f "$_gitlab_values" \
    --timeout 30m
  rm -f "$_gitlab_values"

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

  # Create runner TLS trust secrets (Vault CA chain)
  log_info "Creating runner TLS trust secrets..."
  root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")
  _root_issuer=$(kubectl exec -n vault vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$root_token" \
    vault list -format=json pki/issuers 2>/dev/null | jq -r '.[0]')
  _root_ca=$(kubectl exec -n vault vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$root_token" \
    vault read -field=certificate "pki/issuer/${_root_issuer}" 2>/dev/null)
  _int_issuer=$(kubectl exec -n vault vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$root_token" \
    vault list -format=json pki_int/issuers 2>/dev/null | jq -r '.[0]')
  _int_ca=$(kubectl exec -n vault vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$root_token" \
    vault read -field=certificate "pki_int/issuer/${_int_issuer}" 2>/dev/null)
  _ca_chain="${_root_ca}
${_int_ca}"
  kubectl -n gitlab-runners create secret generic gitlab-runner-certs \
    --from-literal="gitlab.${DOMAIN}.crt=${_ca_chain}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n gitlab-runners create configmap vault-root-ca \
    --from-literal="ca.crt=${_ca_chain}" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Copy runner registration token from gitlab namespace
  log_info "Copying runner registration token..."
  kubectl -n gitlab get secret gitlab-gitlab-runner-secret -o json \
    | jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid,
              .metadata.creationTimestamp, .metadata.managedFields,
              .metadata.ownerReferences, .metadata.annotations)' \
    | kubectl -n gitlab-runners apply -f -

  # Shared runner
  log_info "Installing shared runner..."
  _shared_values=$(mktemp /tmp/shared-runner-values.XXXXXX.yaml)
  _subst_changeme < "${GITLAB_DIR}/runners/shared-runner-values.yaml" > "$_shared_values"
  chmod 600 "$_shared_values"
  helm_install_if_needed gitlab-runner-shared "$HELM_CHART_RUNNER" gitlab-runners \
    -f "$_shared_values" \
    --wait --timeout 5m
  rm -f "$_shared_values"

  # Security runner
  log_info "Installing security runner..."
  _security_values=$(mktemp /tmp/security-runner-values.XXXXXX.yaml)
  _subst_changeme < "${GITLAB_DIR}/runners/security-runner-values.yaml" > "$_security_values"
  chmod 600 "$_security_values"
  helm_install_if_needed gitlab-runner-security "$HELM_CHART_RUNNER" gitlab-runners \
    -f "$_security_values" \
    --wait --timeout 5m
  rm -f "$_security_values"

  # Group runner (platform-services)
  log_info "Installing group runner..."
  _group_values=$(mktemp /tmp/group-runner-values.XXXXXX.yaml)
  _subst_changeme < "${GITLAB_DIR}/runners/group-runner-values.yaml" > "$_group_values"
  chmod 600 "$_group_values"
  helm_install_if_needed gitlab-runner-group "$HELM_CHART_RUNNER" gitlab-runners \
    -f "$_group_values" \
    --wait --timeout 5m
  rm -f "$_group_values"

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
  # NetworkPolicies
  log_info "Applying NetworkPolicies for GitLab services..."
  kubectl apply -f "${REPO_ROOT}/services/gitlab/networkpolicy.yaml"
  kubectl apply -f "${REPO_ROOT}/services/gitlab/runners/networkpolicy.yaml"

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
