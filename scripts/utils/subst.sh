#!/usr/bin/env bash
# subst.sh — Domain placeholder substitution for CHANGEME_* tokens
# Source this file; do not execute directly.
# Requires: log.sh sourced first, DOMAIN/DOMAIN_DASHED/DOMAIN_DOT env vars set
set -euo pipefail

_subst_changeme() {
  [[ -n "${DOMAIN:-}" ]] || die "DOMAIN must be set before using subst functions"
  [[ -n "${DOMAIN_DASHED:-}" ]] || die "DOMAIN_DASHED must be set"
  [[ -n "${DOMAIN_DOT:-}" ]] || die "DOMAIN_DOT must be set"
  # Validate critical passwords are non-empty when explicitly set (avoids blocking non-monitoring deploys)
  if [[ -n "${GRAFANA_ADMIN_PASSWORD+set}" && -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
    die "GRAFANA_ADMIN_PASSWORD is set but empty — refusing to deploy with blank password"
  fi
  sed \
    -e "s|CHANGEME_GRAFANA_ADMIN_PASSWORD|${GRAFANA_ADMIN_PASSWORD:-}|g" \
    -e "s|CHANGEME_KC_REALM|${KC_REALM:-platform}|g" \
    -e "s|CHANGEME_VAULT_ADDR|http://vault.vault.svc.cluster.local:8200|g" \
    -e "s|CHANGEME_HARBOR_ADMIN_PASSWORD|${HARBOR_ADMIN_PASSWORD:-}|g" \
    -e "s|CHANGEME_HARBOR_DB_PASSWORD|${HARBOR_DB_PASSWORD:-}|g" \
    -e "s|CHANGEME_HARBOR_REDIS_PASSWORD|${HARBOR_REDIS_PASSWORD:-}|g" \
    -e "s|CHANGEME_HARBOR_MINIO_SECRET_KEY|${HARBOR_MINIO_SECRET_KEY:-}|g" \
    -e "s|CHANGEME_MINIO_ENDPOINT|http://minio.minio.svc.cluster.local:9000|g" \
    -e "s|CHANGEME_OAUTH2_REDIS_SENTINEL|${OAUTH2_REDIS_SENTINEL:-}|g" \
    -e "s|CHANGEME_KC_ADMIN_PASSWORD|${KC_ADMIN_PASSWORD:-}|g" \
    -e "s|CHANGEME_KEYCLOAK_DB_PASSWORD|${KEYCLOAK_DB_PASSWORD:-}|g" \
    -e "s|CHANGEME_BOOTSTRAP_CLIENT_SECRET|${KEYCLOAK_BOOTSTRAP_CLIENT_SECRET:-}|g" \
    -e "s|CHANGEME_ARGO_ROLLOUTS_PLUGIN_URL|${ARGO_ROLLOUTS_PLUGIN_URL:-}|g" \
    -e "s|CHANGEME_GITLAB_REDIS_PASSWORD|${GITLAB_REDIS_PASSWORD:-}|g" \
    -e "s|CHANGEME_DOMAIN_DOT|${DOMAIN_DOT}|g" \
    -e "s|CHANGEME_DOMAIN_DASHED|${DOMAIN_DASHED}|g" \
    -e "s|CHANGEME_DOMAIN|${DOMAIN}|g"
}

kube_apply_subst() {
  local file substituted
  for file in "$@"; do
    log_info "Applying (substituted): ${file}"
    substituted=$(_subst_changeme < "$file")

    local leftover
    leftover=$(echo "$substituted" | grep -oE 'CHANGEME_[A-Z_]+' | sort -u | head -5) || true
    if [[ -n "$leftover" ]]; then
      die "Unreplaced CHANGEME tokens in $(basename "$file"):
  ${leftover}
  Add missing tokens to _subst_changeme() in scripts/utils/subst.sh"
    fi

    echo "$substituted" | kubectl apply -f -
  done
}
