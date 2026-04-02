#!/usr/bin/env bash
# wait.sh — Kubernetes readiness polling utilities
# Source this file; do not execute directly.
# Requires: log.sh sourced first
set -euo pipefail

wait_for_deployment() {
  local namespace="$1"
  local name="$2"
  local timeout="${3:-600s}"
  log_info "Waiting for deployment/${name} in ${namespace} (timeout: ${timeout})..."
  kubectl -n "$namespace" wait --for=condition=available \
    "deployment/${name}" --timeout="$timeout" 2>/dev/null || {
    log_error "Deployment ${name} in ${namespace} did not become available"
    kubectl -n "$namespace" get pods 2>/dev/null || true
    return 1
  }
  log_ok "deployment/${name} is available"
}

wait_for_pods_ready() {
  local namespace="$1"
  local label="$2"
  local timeout="${3:-600}"
  local interval=5
  local elapsed=0

  log_info "Waiting for pods (${label}) in ${namespace} to be Ready (timeout: ${timeout}s)..."
  while [[ $elapsed -lt $timeout ]]; do
    local total ready
    total=$(kubectl -n "$namespace" get pods -l "$label" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ready=$(kubectl -n "$namespace" get pods -l "$label" \
      -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
      2>/dev/null | grep -c "True" || true)

    if [[ "$total" -gt 0 && "$total" -eq "$ready" ]]; then
      log_ok "All ${total} pod(s) with label ${label} are Ready"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  log_error "Timeout waiting for pods (${label}) in ${namespace}"
  kubectl -n "$namespace" get pods -l "$label" 2>/dev/null || true
  return 1
}

wait_for_pods_running() {
  local namespace="$1"
  local label="$2"
  local expected="${3:-1}"
  local timeout="${4:-600}"
  local interval=5
  local elapsed=0

  log_info "Waiting for ${expected} pod(s) (${label}) in ${namespace} to be Running (timeout: ${timeout}s)..."
  while [[ $elapsed -lt $timeout ]]; do
    local running
    running=$(kubectl -n "$namespace" get pods -l "$label" \
      --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$running" -ge "$expected" ]]; then
      log_ok "${running} pod(s) with label ${label} are Running"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  log_error "Timeout waiting for ${expected} Running pods (${label}) in ${namespace}"
  kubectl -n "$namespace" get pods -l "$label" 2>/dev/null || true
  return 1
}

wait_for_clusterissuer() {
  local name="$1"
  local timeout="${2:-600}"
  local interval=5
  local elapsed=0

  log_info "Waiting for ClusterIssuer/${name} to be Ready..."
  while [[ $elapsed -lt $timeout ]]; do
    local ready
    ready=$(kubectl get clusterissuer "$name" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [[ "$ready" == "True" ]]; then
      log_ok "ClusterIssuer/${name} is Ready"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  log_error "ClusterIssuer/${name} did not become Ready"
  kubectl get clusterissuer "$name" -o yaml 2>/dev/null | tail -20
  return 1
}

wait_for_tls_secret() {
  local namespace="$1"
  local secret_name="$2"
  local timeout="${3:-600}"
  local interval=5
  local elapsed=0

  log_info "Waiting for TLS secret ${secret_name} in ${namespace}..."
  while [[ $elapsed -lt $timeout ]]; do
    if kubectl -n "$namespace" get secret "$secret_name" &>/dev/null; then
      log_ok "TLS secret ${secret_name} exists"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  log_warn "TLS secret ${secret_name} not found after ${timeout}s (cert-manager may still be issuing)"
  return 0
}
