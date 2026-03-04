#!/usr/bin/env bash
# subst.sh — Domain placeholder substitution for CHANGEME_* tokens
# Source this file; do not execute directly.
# Requires: log.sh sourced first, DOMAIN/DOMAIN_DASHED/DOMAIN_DOT env vars set
set -euo pipefail

_subst_changeme() {
  [[ -n "${DOMAIN:-}" ]] || die "DOMAIN must be set before using subst functions"
  [[ -n "${DOMAIN_DASHED:-}" ]] || die "DOMAIN_DASHED must be set"
  [[ -n "${DOMAIN_DOT:-}" ]] || die "DOMAIN_DOT must be set"
  sed \
    -e "s|CHANGEME_GRAFANA_ADMIN_PASSWORD|${GRAFANA_ADMIN_PASSWORD:-}|g" \
    -e "s|CHANGEME_KC_REALM|${KC_REALM:-master}|g" \
    -e "s|CHANGEME_VAULT_ADDR|http://vault.vault.svc.cluster.local:8200|g" \
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
