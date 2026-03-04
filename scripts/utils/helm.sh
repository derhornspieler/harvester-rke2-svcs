#!/usr/bin/env bash
# helm.sh — Idempotent Helm repo and install operations
# Source this file; do not execute directly.
# Requires: log.sh sourced first
set -euo pipefail

helm_repo_add() {
  local name="$1"
  local url="$2"
  if helm repo list 2>/dev/null | grep -q "^${name}"; then
    log_info "Helm repo '${name}' already exists, updating..."
    helm repo update "$name"
  else
    log_info "Adding Helm repo '${name}' -> ${url}"
    helm repo add "$name" "$url"
  fi
}

helm_install_if_needed() {
  local release="$1"
  local chart="$2"
  local namespace="$3"
  shift 3

  if helm status "$release" -n "$namespace" &>/dev/null; then
    log_info "Helm release '${release}' already exists in ${namespace}, upgrading..."
    helm upgrade "$release" "$chart" -n "$namespace" "$@"
  else
    log_info "Installing Helm release '${release}' from ${chart} into ${namespace}..."
    helm install "$release" "$chart" -n "$namespace" --create-namespace "$@"
  fi
}
