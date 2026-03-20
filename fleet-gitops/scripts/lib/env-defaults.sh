#!/usr/bin/env bash
# env-defaults.sh — Compute derived variables from .env base values
# Sourced by render-templates.sh and other scripts AFTER .env is loaded
#
# This file computes FQDNs, OIDC URLs, TLS secret names, and other
# values that can be derived from the base .env configuration.

set -euo pipefail

# Require base variables
: "${DOMAIN:?DOMAIN must be set in .env}"
: "${HARBOR_HOST:?HARBOR_HOST must be set in .env}"

# --- Defaults for optional base variables ---
export KEYCLOAK_REALM="${KEYCLOAK_REALM:-platform}"
export S3_REGION="${S3_REGION:-us-east-1}"
export STORAGE_CLASS="${STORAGE_CLASS:-longhorn}"
export GATEWAY_CLASS="${GATEWAY_CLASS:-traefik}"
export ORG="${ORG:-${DOMAIN}}"
export FLEET_TARGET_CLUSTER="${FLEET_TARGET_CLUSTER:-rke2-prod}"
export FLEET_NAMESPACE="${FLEET_NAMESPACE:-fleet-default}"
export REDIS_MASTER_NAME="${REDIS_MASTER_NAME:-mymaster}"

# --- Vault defaults ---
export VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-kv}"
export VAULT_PKI_MOUNT="${VAULT_PKI_MOUNT:-pki_int}"
export VAULT_K8S_AUTH_PATH="${VAULT_K8S_AUTH_PATH:-auth/kubernetes}"
export VAULT_INTERNAL_URL="${VAULT_INTERNAL_URL:-http://vault.vault.svc.cluster.local:8200}"

# --- Internal service URLs ---
export MINIO_INTERNAL_URL="${MINIO_INTERNAL_URL:-http://minio.minio.svc.cluster.local:9000}"
export MINIO_INTERNAL_HOST="${MINIO_INTERNAL_HOST:-minio.minio.svc.cluster.local}"
export PROMETHEUS_INTERNAL_URL="${PROMETHEUS_INTERNAL_URL:-http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090}"
export LOKI_INTERNAL_URL="${LOKI_INTERNAL_URL:-http://loki.monitoring.svc:3100}"
export KEYCLOAK_INTERNAL_URL="${KEYCLOAK_INTERNAL_URL:-http://keycloak.keycloak.svc.cluster.local:8080}"

# --- Database hosts ---
export KEYCLOAK_DB_HOST="${KEYCLOAK_DB_HOST:-keycloak-pg-rw.database.svc.cluster.local}"
export KEYCLOAK_DB_NAME="${KEYCLOAK_DB_NAME:-keycloak}"
export GRAFANA_DB_HOST="${GRAFANA_DB_HOST:-grafana-pg-rw.database.svc.cluster.local:5432}"
export GRAFANA_DB_NAME="${GRAFANA_DB_NAME:-grafana}"
export HARBOR_DB_HOST="${HARBOR_DB_HOST:-harbor-pg-rw.database.svc.cluster.local}"
export HARBOR_DB_NAME="${HARBOR_DB_NAME:-registry}"
export GITLAB_DB_HOST_RW="${GITLAB_DB_HOST_RW:-gitlab-pg-pooler-rw.database.svc.cluster.local}"
export GITLAB_DB_HOST_RO="${GITLAB_DB_HOST_RO:-gitlab-pg-pooler-ro.database.svc.cluster.local}"
export GITLAB_DB_NAME="${GITLAB_DB_NAME:-gitlabhq_production}"

# --- Redis/Valkey sentinel endpoints ---
export HARBOR_REDIS_SENTINEL="${HARBOR_REDIS_SENTINEL:-harbor-redis-sentinel.harbor.svc.cluster.local:26379}"
export GITLAB_REDIS_SENTINEL="${GITLAB_REDIS_SENTINEL:-gitlab-redis-sentinel.gitlab.svc.cluster.local}"

# --- Grafana plugin (air-gapped) ---
export GRAFANA_PLUGIN_LOKIEXPLORE_VER="${GRAFANA_PLUGIN_LOKIEXPLORE_VER:-}"
export MINIO_BUCKET_GRAFANA_PLUGINS="${MINIO_BUCKET_GRAFANA_PLUGINS:-grafana-plugins}"
if [[ -n "${GRAFANA_PLUGIN_LOKIEXPLORE_VER}" ]]; then
  export GRAFANA_PLUGIN_INSTALL_URL="http://minio.minio.svc.cluster.local:9000/${MINIO_BUCKET_GRAFANA_PLUGINS}/grafana-lokiexplore-app-${GRAFANA_PLUGIN_LOKIEXPLORE_VER}.zip;grafana-lokiexplore-app"
else
  export GRAFANA_PLUGIN_INSTALL_URL=""
fi

# --- MinIO bucket names ---
export MINIO_BUCKET_HARBOR="${MINIO_BUCKET_HARBOR:-harbor}"
export MINIO_BUCKET_CNPG_BACKUPS="${MINIO_BUCKET_CNPG_BACKUPS:-cnpg-backups}"
export MINIO_BUCKET_GITLAB_LFS="${MINIO_BUCKET_GITLAB_LFS:-gitlab-lfs}"
export MINIO_BUCKET_GITLAB_ARTIFACTS="${MINIO_BUCKET_GITLAB_ARTIFACTS:-gitlab-artifacts}"
export MINIO_BUCKET_GITLAB_UPLOADS="${MINIO_BUCKET_GITLAB_UPLOADS:-gitlab-uploads}"
export MINIO_BUCKET_GITLAB_PACKAGES="${MINIO_BUCKET_GITLAB_PACKAGES:-gitlab-packages}"
export MINIO_BUCKET_GITLAB_PAGES="${MINIO_BUCKET_GITLAB_PAGES:-gitlab-pages}"
export MINIO_BUCKET_GITLAB_MR_DIFFS="${MINIO_BUCKET_GITLAB_MR_DIFFS:-gitlab-mr-diffs}"
export MINIO_BUCKET_GITLAB_TERRAFORM="${MINIO_BUCKET_GITLAB_TERRAFORM:-gitlab-terraform}"
export MINIO_BUCKET_GITLAB_CI_SECURE_FILES="${MINIO_BUCKET_GITLAB_CI_SECURE_FILES:-gitlab-ci-secure-files}"
export MINIO_BUCKET_GITLAB_DEPENDENCY_PROXY="${MINIO_BUCKET_GITLAB_DEPENDENCY_PROXY:-gitlab-dependency-proxy}"

# --- Derived FQDNs (override in .env if non-standard) ---
export KEYCLOAK_FQDN="${KEYCLOAK_FQDN:-keycloak.${DOMAIN}}"
export VAULT_FQDN="${VAULT_FQDN:-vault.${DOMAIN}}"
export GITLAB_FQDN="${GITLAB_FQDN:-gitlab.${DOMAIN}}"
export KAS_FQDN="${KAS_FQDN:-kas.${DOMAIN}}"
export ARGOCD_FQDN="${ARGOCD_FQDN:-argo.${DOMAIN}}"
export ROLLOUTS_FQDN="${ROLLOUTS_FQDN:-rollouts.${DOMAIN}}"
export WORKFLOWS_FQDN="${WORKFLOWS_FQDN:-workflows.${DOMAIN}}"
export GRAFANA_FQDN="${GRAFANA_FQDN:-grafana.${DOMAIN}}"
export PROMETHEUS_FQDN="${PROMETHEUS_FQDN:-prometheus.${DOMAIN}}"
export ALERTMANAGER_FQDN="${ALERTMANAGER_FQDN:-alertmanager.${DOMAIN}}"
export HUBBLE_FQDN="${HUBBLE_FQDN:-hubble.${DOMAIN}}"
export TRAEFIK_FQDN="${TRAEFIK_FQDN:-traefik.${DOMAIN}}"
export HARBOR_FQDN="${HARBOR_FQDN:-${HARBOR_HOST}}"
export RANCHER_FQDN="${RANCHER_FQDN:-rancher.hvst-vip.${DOMAIN}}"

# --- Derived OIDC URLs ---
export OIDC_ISSUER_URL="${OIDC_ISSUER_URL:-https://${KEYCLOAK_FQDN}/realms/${KEYCLOAK_REALM}}"

# --- Derived TLS secret names (dots to dashes, append -tls) ---
export KEYCLOAK_TLS_SECRET="${KEYCLOAK_FQDN//./-}-tls"
export VAULT_TLS_SECRET="${VAULT_FQDN//./-}-tls"
export GITLAB_TLS_SECRET="${GITLAB_FQDN//./-}-tls"
export KAS_TLS_SECRET="${KAS_FQDN//./-}-tls"
export ARGOCD_TLS_SECRET="${ARGOCD_FQDN//./-}-tls"
export ROLLOUTS_TLS_SECRET="${ROLLOUTS_FQDN//./-}-tls"
export WORKFLOWS_TLS_SECRET="${WORKFLOWS_FQDN//./-}-tls"
export GRAFANA_TLS_SECRET="${GRAFANA_FQDN//./-}-tls"
export PROMETHEUS_TLS_SECRET="${PROMETHEUS_FQDN//./-}-tls"
export ALERTMANAGER_TLS_SECRET="${ALERTMANAGER_FQDN//./-}-tls"
export HUBBLE_TLS_SECRET="${HUBBLE_FQDN//./-}-tls"
export TRAEFIK_TLS_SECRET="${TRAEFIK_FQDN//./-}-tls"
export HARBOR_TLS_SECRET="${HARBOR_FQDN//./-}-tls"

# --- Derived GitLab URL ---
export GITLAB_URL="${GITLAB_URL:-https://${GITLAB_FQDN}}"

# --- Derived Harbor URLs ---
export HARBOR_EXTERNAL_URL="${HARBOR_EXTERNAL_URL:-https://${HARBOR_FQDN}}"
export OCI_HELM_PREFIX="${OCI_HELM_PREFIX:-oci://${HARBOR_HOST}/helm}"
export OCI_FLEET_PREFIX="${OCI_FLEET_PREFIX:-oci://${HARBOR_HOST}/fleet}"

# --- Per-chart OCI URI overrides ---
# Set any OCI_CHART_* in .env to override the full OCI path for a specific chart.
# Example: OCI_CHART_VAULT=oci://harbor.dmz.tiger.net/charts.hashicorp.com/vault
export OCI_CHART_PROMETHEUS_CRDS="${OCI_CHART_PROMETHEUS_CRDS:-${OCI_HELM_PREFIX}/prometheus-operator-crds}"
export OCI_CHART_CNPG="${OCI_CHART_CNPG:-${OCI_HELM_PREFIX}/cloudnative-pg}"
export OCI_CHART_REDIS_OPERATOR="${OCI_CHART_REDIS_OPERATOR:-${OCI_HELM_PREFIX}/redis-operator}"
export OCI_CHART_CERT_MANAGER="${OCI_CHART_CERT_MANAGER:-${OCI_HELM_PREFIX}/cert-manager}"
export OCI_CHART_VAULT="${OCI_CHART_VAULT:-${OCI_HELM_PREFIX}/vault}"
export OCI_CHART_EXTERNAL_SECRETS="${OCI_CHART_EXTERNAL_SECRETS:-${OCI_HELM_PREFIX}/external-secrets}"
export OCI_CHART_EXTERNAL_DNS="${OCI_CHART_EXTERNAL_DNS:-${OCI_HELM_PREFIX}/external-dns}"
export OCI_CHART_PROMETHEUS_STACK="${OCI_CHART_PROMETHEUS_STACK:-${OCI_HELM_PREFIX}/kube-prometheus-stack}"
export OCI_CHART_HARBOR="${OCI_CHART_HARBOR:-${OCI_HELM_PREFIX}/harbor}"
export OCI_CHART_ARGOCD="${OCI_CHART_ARGOCD:-${OCI_HELM_PREFIX}/argo-cd}"
export OCI_CHART_ARGO_ROLLOUTS="${OCI_CHART_ARGO_ROLLOUTS:-${OCI_HELM_PREFIX}/argo-rollouts}"
export OCI_CHART_ARGO_WORKFLOWS="${OCI_CHART_ARGO_WORKFLOWS:-${OCI_HELM_PREFIX}/argo-workflows}"
export OCI_CHART_KEYCLOAKX="${OCI_CHART_KEYCLOAKX:-${OCI_HELM_PREFIX}/keycloakx}"
export OCI_CHART_GITLAB="${OCI_CHART_GITLAB:-${OCI_HELM_PREFIX}/gitlab}"
export OCI_CHART_GITLAB_RUNNER="${OCI_CHART_GITLAB_RUNNER:-${OCI_HELM_PREFIX}/gitlab-runner}"

# --- Vault PKI role (domain dots replaced by -dot-) ---
export VAULT_PKI_ROLE="${VAULT_PKI_ROLE:-${VAULT_PKI_MOUNT}/sign/${DOMAIN//./-dot-}}"

# --- Admin ---
export PLATFORM_ADMIN_EMAIL="${PLATFORM_ADMIN_EMAIL:-admin@${DOMAIN}}"
export PLATFORM_ADMIN_NAME="${PLATFORM_ADMIN_NAME:-Platform Admin}"
export PLATFORM_ADMIN_USER="${PLATFORM_ADMIN_USER:-admin.user}"

# --- Senior Developer ---
export SENIOR_DEV_USER="${SENIOR_DEV_USER:-dev.user}"
export SENIOR_DEV_NAME="${SENIOR_DEV_NAME:-Senior Developer}"
export SENIOR_DEV_EMAIL="${SENIOR_DEV_EMAIL:-dev@${DOMAIN}}"

# --- CI Service Account ---
export CI_SERVICE_USER="${CI_SERVICE_USER:-gitlab-ci}"
export CI_SERVICE_NAME="${CI_SERVICE_NAME:-GitLab CI}"
export CI_SERVICE_EMAIL="${CI_SERVICE_EMAIL:-gitlab-ci@${DOMAIN}}"

# --- CI Deploy Key (SSH) ---
# Resolve relative paths against FLEET_DIR
if [[ -n "${CI_DEPLOY_PRIVATE_KEY_FILE:-}" && "${CI_DEPLOY_PRIVATE_KEY_FILE}" != /* ]]; then
  _ENV_DEFAULTS_DIR2="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _FLEET_DIR2="$(dirname "$(dirname "${_ENV_DEFAULTS_DIR2}")")"
  CI_DEPLOY_PRIVATE_KEY_FILE="${_FLEET_DIR2}/${CI_DEPLOY_PRIVATE_KEY_FILE#./}"
fi
if [[ -n "${CI_DEPLOY_PUBLIC_KEY_FILE:-}" && "${CI_DEPLOY_PUBLIC_KEY_FILE}" != /* ]]; then
  _ENV_DEFAULTS_DIR2="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _FLEET_DIR2="$(dirname "$(dirname "${_ENV_DEFAULTS_DIR2}")")"
  CI_DEPLOY_PUBLIC_KEY_FILE="${_FLEET_DIR2}/${CI_DEPLOY_PUBLIC_KEY_FILE#./}"
fi
if [[ -n "${CI_DEPLOY_PRIVATE_KEY_FILE:-}" && -f "${CI_DEPLOY_PRIVATE_KEY_FILE}" ]]; then
  export CI_DEPLOY_PRIVATE_KEY_B64
  CI_DEPLOY_PRIVATE_KEY_B64="$(base64 -w0 < "${CI_DEPLOY_PRIVATE_KEY_FILE}")"
else
  export CI_DEPLOY_PRIVATE_KEY_B64="${CI_DEPLOY_PRIVATE_KEY_B64:-}"
fi
if [[ -n "${CI_DEPLOY_PUBLIC_KEY_FILE:-}" && -f "${CI_DEPLOY_PUBLIC_KEY_FILE}" ]]; then
  export CI_DEPLOY_PUBLIC_KEY
  CI_DEPLOY_PUBLIC_KEY="$(cat "${CI_DEPLOY_PUBLIC_KEY_FILE}")"
else
  export CI_DEPLOY_PUBLIC_KEY="${CI_DEPLOY_PUBLIC_KEY:-}"
fi

# --- GitHub mirror ---
export GITHUB_API_TOKEN="${GITHUB_API_TOKEN:-}"
export GITHUB_MIRROR_URL="${GITHUB_MIRROR_URL:-}"
export GITHUB_MIRROR_REPO="${GITHUB_MIRROR_REPO:-}"
export GITHUB_SSH_PRIVATE_KEY_FILE="${GITHUB_SSH_PRIVATE_KEY_FILE:-}"

# --- RBAC groups ---
export RBAC_GROUP_ADMINS="${RBAC_GROUP_ADMINS:-platform-admins}"
export RBAC_GROUP_INFRA="${RBAC_GROUP_INFRA:-infra-engineers}"
export RBAC_GROUP_NETWORK="${RBAC_GROUP_NETWORK:-network-engineers}"
export RBAC_GROUP_SENIOR_DEVS="${RBAC_GROUP_SENIOR_DEVS:-senior-developers}"
export RBAC_GROUP_DEVS="${RBAC_GROUP_DEVS:-developers}"

# --- Keycloak image splitting (Helm chart needs separate repo + tag) ---
if [[ -n "${IMAGE_KEYCLOAK:-}" ]]; then
  export IMAGE_KEYCLOAK_REPO="${IMAGE_KEYCLOAK_REPO:-${IMAGE_KEYCLOAK%%:*}}"
  export IMAGE_KEYCLOAK_TAG="${IMAGE_KEYCLOAK_TAG:-${IMAGE_KEYCLOAK##*:}}"
else
  export IMAGE_KEYCLOAK_REPO="${IMAGE_KEYCLOAK_REPO:-quay.io/keycloak/keycloak}"
  export IMAGE_KEYCLOAK_TAG="${IMAGE_KEYCLOAK_TAG:-}"
fi

# --- Root CA cert content (read from file if provided) ---
# Resolve relative paths against FLEET_DIR (parent of scripts/)
if [[ -n "${ROOT_CA_PEM_FILE:-}" && "${ROOT_CA_PEM_FILE}" != /* ]]; then
  _ENV_DEFAULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _FLEET_DIR="$(dirname "$(dirname "${_ENV_DEFAULTS_DIR}")")"
  ROOT_CA_PEM_FILE="${_FLEET_DIR}/${ROOT_CA_PEM_FILE#./}"
fi
if [[ -n "${ROOT_CA_PEM_FILE:-}" && -f "${ROOT_CA_PEM_FILE}" ]]; then
  export ROOT_CA_PEM_CONTENT
  ROOT_CA_PEM_CONTENT="$(cat "${ROOT_CA_PEM_FILE}")"
  export ROOT_CA_PEM_B64
  ROOT_CA_PEM_B64="$(base64 -w0 < "${ROOT_CA_PEM_FILE}")"
  # Indented versions for YAML embedding
  export ROOT_CA_PEM_INDENT2
  ROOT_CA_PEM_INDENT2="$(sed 's/^/  /' "${ROOT_CA_PEM_FILE}")"
  export ROOT_CA_PEM_INDENT4
  ROOT_CA_PEM_INDENT4="$(sed 's/^/    /' "${ROOT_CA_PEM_FILE}")"
  export ROOT_CA_PEM_INDENT8
  ROOT_CA_PEM_INDENT8="$(sed 's/^/        /' "${ROOT_CA_PEM_FILE}")"
else
  export ROOT_CA_PEM_CONTENT="${ROOT_CA_PEM_CONTENT:-}"
  export ROOT_CA_PEM_B64="${ROOT_CA_PEM_B64:-}"
  export ROOT_CA_PEM_INDENT2="${ROOT_CA_PEM_INDENT2:-}"
  export ROOT_CA_PEM_INDENT4="${ROOT_CA_PEM_INDENT4:-}"
  export ROOT_CA_PEM_INDENT8="${ROOT_CA_PEM_INDENT8:-}"
fi

# --- LDAP CA cert content (optional, for LDAPS user federation in Keycloak) ---
if [[ -n "${LDAP_CA_PEM_FILE:-}" && "${LDAP_CA_PEM_FILE}" != /* ]]; then
  _ENV_DEFAULTS_DIR="${_ENV_DEFAULTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  _FLEET_DIR="${_FLEET_DIR:-$(dirname "$(dirname "${_ENV_DEFAULTS_DIR}")")}"
  LDAP_CA_PEM_FILE="${_FLEET_DIR}/${LDAP_CA_PEM_FILE#./}"
fi
if [[ -n "${LDAP_CA_PEM_FILE:-}" && -f "${LDAP_CA_PEM_FILE}" ]]; then
  export LDAP_CA_PEM_INDENT4
  LDAP_CA_PEM_INDENT4="$(sed 's/^/    /' "${LDAP_CA_PEM_FILE}")"
else
  export LDAP_CA_PEM_INDENT4="${LDAP_CA_PEM_INDENT4:-}"
fi

# --- ENVSUBST variable list ---
# Explicit list of variables that render-templates.sh will substitute.
# Any $VAR not in this list is LEFT AS-IS (critical for embedded bash in Jobs).
export ENVSUBST_VARS='${DOMAIN} ${HARBOR_HOST} ${HARBOR_FQDN} ${HARBOR_EXTERNAL_URL}
${KEYCLOAK_FQDN} ${KEYCLOAK_TLS_SECRET} ${KEYCLOAK_REALM}
${VAULT_FQDN} ${VAULT_TLS_SECRET}
${GITLAB_FQDN} ${GITLAB_TLS_SECRET} ${GITLAB_URL}
${KAS_FQDN} ${KAS_TLS_SECRET}
${ARGOCD_FQDN} ${ARGOCD_TLS_SECRET}
${ROLLOUTS_FQDN} ${ROLLOUTS_TLS_SECRET}
${WORKFLOWS_FQDN} ${WORKFLOWS_TLS_SECRET}
${GRAFANA_FQDN} ${GRAFANA_TLS_SECRET}
${PROMETHEUS_FQDN} ${PROMETHEUS_TLS_SECRET}
${ALERTMANAGER_FQDN} ${ALERTMANAGER_TLS_SECRET}
${HUBBLE_FQDN} ${HUBBLE_TLS_SECRET}
${TRAEFIK_FQDN} ${TRAEFIK_TLS_SECRET}
${HARBOR_TLS_SECRET}
${OIDC_ISSUER_URL}
${FLEET_TARGET_CLUSTER} ${FLEET_NAMESPACE}
${TRAEFIK_LB_IP} ${DNS_SERVER_IP} ${DNS_ZONE}
${TSIG_KEY_NAME}
${S3_REGION} ${STORAGE_CLASS} ${GATEWAY_CLASS}
${VAULT_INTERNAL_URL} ${MINIO_INTERNAL_URL} ${MINIO_INTERNAL_HOST}
${PROMETHEUS_INTERNAL_URL} ${LOKI_INTERNAL_URL}
${KEYCLOAK_INTERNAL_URL}
${KEYCLOAK_DB_HOST} ${KEYCLOAK_DB_NAME}
${GRAFANA_DB_HOST} ${GRAFANA_DB_NAME}
${HARBOR_DB_HOST} ${HARBOR_DB_NAME}
${GITLAB_DB_HOST_RW} ${GITLAB_DB_HOST_RO} ${GITLAB_DB_NAME}
${REDIS_MASTER_NAME}
${HARBOR_REDIS_SENTINEL} ${GITLAB_REDIS_SENTINEL}
${VAULT_PKI_ROLE}
${RBAC_GROUP_ADMINS} ${RBAC_GROUP_INFRA} ${RBAC_GROUP_NETWORK}
${RBAC_GROUP_SENIOR_DEVS} ${RBAC_GROUP_DEVS}
${PLATFORM_ADMIN_USER} ${PLATFORM_ADMIN_NAME} ${PLATFORM_ADMIN_EMAIL}
${SENIOR_DEV_USER} ${SENIOR_DEV_NAME} ${SENIOR_DEV_EMAIL}
${CI_SERVICE_USER} ${CI_SERVICE_NAME} ${CI_SERVICE_EMAIL}
${CI_DEPLOY_PRIVATE_KEY_B64} ${CI_DEPLOY_PUBLIC_KEY}
${IMAGE_ALPINE_K8S} ${IMAGE_CURL} ${IMAGE_KEYCLOAK}
${IMAGE_KEYCLOAK_REPO} ${IMAGE_KEYCLOAK_TAG}
${IMAGE_POSTGRESQL_17} ${IMAGE_POSTGRESQL_16}
${IMAGE_REDIS} ${IMAGE_REDIS_SENTINEL} ${IMAGE_REDIS_EXPORTER}
${IMAGE_MINIO} ${IMAGE_MINIO_MC}
${IMAGE_LOKI} ${IMAGE_ALLOY} ${IMAGE_OAUTH2_PROXY}
${IMAGE_NODE_LABELER} ${IMAGE_STORAGE_AUTOSCALER} ${IMAGE_CLUSTER_AUTOSCALER}
${AUTOSCALER_SCALE_DOWN_DELAY_AFTER_ADD} ${AUTOSCALER_SCALE_DOWN_DELAY_AFTER_DELETE} \
${AUTOSCALER_SCALE_DOWN_UNNEEDED_TIME} ${AUTOSCALER_SCALE_DOWN_UTILIZATION_THRESHOLD} \
${IMAGE_VAULT} ${IMAGE_VALKEY} ${IMAGE_HAPROXY}
${MINIO_BUCKET_HARBOR} ${MINIO_BUCKET_CNPG_BACKUPS} ${MINIO_BUCKET_GRAFANA_PLUGINS}
${GRAFANA_PLUGIN_LOKIEXPLORE_VER} ${GRAFANA_PLUGIN_INSTALL_URL}
${MINIO_BUCKET_GITLAB_LFS} ${MINIO_BUCKET_GITLAB_ARTIFACTS}
${MINIO_BUCKET_GITLAB_UPLOADS} ${MINIO_BUCKET_GITLAB_PACKAGES}
${MINIO_BUCKET_GITLAB_PAGES}
${MINIO_BUCKET_GITLAB_MR_DIFFS} ${MINIO_BUCKET_GITLAB_TERRAFORM}
${MINIO_BUCKET_GITLAB_CI_SECURE_FILES} ${MINIO_BUCKET_GITLAB_DEPENDENCY_PROXY}
${OCI_HELM_PREFIX} ${OCI_FLEET_PREFIX}
${CHART_VER_CERT_MANAGER} ${CHART_VER_VAULT} ${CHART_VER_EXTERNAL_SECRETS}
${CHART_VER_CNPG} ${CHART_VER_REDIS_OPERATOR} ${CHART_VER_EXTERNAL_DNS}
${CHART_VER_PROMETHEUS_CRDS} ${CHART_VER_PROMETHEUS_STACK}
${CHART_VER_HARBOR} ${CHART_VER_ARGOCD} ${CHART_VER_ARGO_ROLLOUTS}
${CHART_VER_KEYCLOAKX}
${CHART_VER_ARGO_WORKFLOWS} ${CHART_VER_GITLAB} ${CHART_VER_GITLAB_RUNNER}
${ROOT_CA_PEM_CONTENT} ${ROOT_CA_PEM_B64}
${ROOT_CA_PEM_INDENT2} ${ROOT_CA_PEM_INDENT4} ${ROOT_CA_PEM_INDENT8}
${LDAP_CA_PEM_INDENT4}
${VAULT_PKI_MOUNT}
${ORG}
${RANCHER_FQDN}
${HARBOR_USER} ${HARBOR_PASS}'
