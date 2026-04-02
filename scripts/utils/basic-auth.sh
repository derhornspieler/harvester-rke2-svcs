#!/usr/bin/env bash
# basic-auth.sh — Generate htpasswd Secret for Traefik basic-auth middleware
# Source this file; do not execute directly.
# Requires: log.sh sourced first
set -euo pipefail

create_basic_auth_secret() {
  local namespace="$1"
  local name="$2"
  local username="$3"
  local password="$4"

  local htpasswd
  htpasswd=$(htpasswd -nb "$username" "$password")

  log_info "Creating basic-auth secret ${name} in ${namespace}..."
  kubectl create secret generic "$name" \
    --namespace="$namespace" \
    --from-literal=users="$htpasswd" \
    --dry-run=client -o yaml | kubectl apply -f -
  log_ok "Basic-auth secret ${name} created"
}
