#!/usr/bin/env bash
# vault.sh — Vault init, unseal, and exec operations via kubectl
# Source this file; do not execute directly.
# Requires: log.sh sourced first
set -euo pipefail

vault_exec() {
  local root_token="$1"
  shift
  kubectl exec -n vault vault-0 -- env \
    VAULT_ADDR=http://127.0.0.1:8200 \
    VAULT_TOKEN="$root_token" \
    vault "$@"
}

vault_init() {
  local output_file="$1"
  log_info "Initializing Vault (5 shares, threshold 3)..."
  kubectl exec -n vault vault-0 -- \
    vault operator init -key-shares=5 -key-threshold=3 -format=json > "$output_file"

  local key_count
  key_count=$(jq '(.unseal_keys_hex // .keys) | length' "$output_file")
  [[ "$key_count" -eq 5 ]] || die "Expected 5 unseal keys, got ${key_count}"
  log_ok "Vault initialized - ${key_count} unseal keys captured"
}

vault_unseal_replica() {
  local replica="$1"
  local init_file="$2"

  log_info "Unsealing vault-${replica}..."
  for k in 0 1 2; do
    local key
    key=$(jq -r "(.unseal_keys_hex // .keys)[${k}]" "$init_file")
    kubectl exec -n vault "vault-${replica}" -- vault operator unseal "$key" >/dev/null
  done
}

vault_unseal_all() {
  local init_file="$1"
  for i in 0 1 2; do
    vault_unseal_replica "$i" "$init_file"
  done
  log_ok "All 3 Vault replicas unsealed"
}

vault_is_initialized() {
  local status
  status=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null | jq -r '.initialized' || echo "false")
  [[ "$status" == "true" ]]
}

vault_is_sealed() {
  local status
  status=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "true")
  [[ "$status" == "true" ]]
}
