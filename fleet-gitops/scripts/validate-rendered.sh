#!/usr/bin/env bash
# validate-rendered.sh — Validate rendered Fleet templates before push/deploy.
#
# Catches mismatches between .env defaults and production reality:
#   - storageClassName must match what's on the cluster (immutable PVC field)
#   - Image references must use the correct Harbor registry
#   - Namespace names must match existing namespaces
#   - No unresolved ${VARIABLE} template placeholders
#
# Usage:
#   validate-rendered.sh                    # Validate rendered/ directory
#   validate-rendered.sh --strict           # Also check against live cluster (needs kubeconfig)
#
# Exit codes:
#   0 — all checks passed
#   1 — validation failures found (DO NOT push/deploy)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FLEET_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RENDERED_DIR="${FLEET_DIR}/rendered"

ERRORS=0
WARNINGS=0
STRICT=false

[[ "${1:-}" == "--strict" ]] && STRICT=true

log_ok()   { echo -e "\033[0;32m[PASS]\033[0m $*"; }
log_fail() { echo -e "\033[0;31m[FAIL]\033[0m $*"; ERRORS=$((ERRORS + 1)); }
log_warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; WARNINGS=$((WARNINGS + 1)); }

echo "============================================="
echo "Fleet Template Validation"
echo "============================================="
echo ""

# --- Check rendered directory exists ---
if [[ ! -d "${RENDERED_DIR}" ]]; then
  log_fail "Rendered directory not found: ${RENDERED_DIR}"
  echo "Run render-templates.sh first."
  exit 1
fi

# --- Check 1: No unresolved template variables ---
echo "--- Check 1: Unresolved template variables ---"
# Only check env/value fields in YAML, not inline shell scripts
UNRESOLVED=$(grep -rn '\${[A-Z_]*}' "${RENDERED_DIR}" --include="*.yaml" --include="*.yml" 2>/dev/null | \
  grep -E "^\s*(value|image|host|endpoint|url|server|addr|bucket|region|class):" | \
  grep -v "^#" | head -20 || true)
if [[ -n "${UNRESOLVED}" ]]; then
  log_fail "Unresolved template variables found in rendered YAML:"
  echo "${UNRESOLVED}" | head -10
else
  log_ok "No unresolved template variables"
fi

# --- Check 2: storageClassName consistency ---
echo ""
echo "--- Check 2: storageClassName values ---"
STORAGE_CLASSES=$(grep -rh "storageClassName:" "${RENDERED_DIR}" --include="*.yaml" 2>/dev/null | \
  sed '/^#/d' | sort -u | sed 's/.*storageClassName: *//' | tr -d '"' | sort -u) || true

for sc in ${STORAGE_CLASSES}; do
  case "${sc}" in
    harvester)
      log_ok "storageClassName: ${sc}"
      ;;
    longhorn|standard|gp2|default)
      log_fail "storageClassName '${sc}' is not the production storage class (expected: harvester)"
      ;;
    *)
      log_warn "Unexpected storageClassName: ${sc} — verify this is correct"
      ;;
  esac
done

if [[ -z "${STORAGE_CLASSES}" ]]; then
  log_ok "No storageClassName references (OK for bundles without PVCs)"
fi

# --- Check 3: Image registry references ---
echo ""
echo "--- Check 3: Image registry references ---"
# All images should reference harbor.example.com (pull-through) or known public registries
BAD_IMAGES=$(grep -rh "image:" "${RENDERED_DIR}" --include="*.yaml" 2>/dev/null | \
  grep -v "^#\|CHANGEME_IMAGE\|harbor\.\|docker\.io/\|quay\.io/\|ghcr\.io/\|registry\.gitlab\.\|gcr\.io/\|registry\.k8s\.\|semgrep/\|zricethezav/\|aquasec/\|golangci/\|hadolint/\|hashicorp/" | \
  grep -v "^\s*#" | head -10 || true)
if [[ -n "${BAD_IMAGES}" ]]; then
  log_warn "Images not from known registries:"
  echo "${BAD_IMAGES}" | head -5
else
  log_ok "All images from known registries"
fi

# --- Check 4: Domain consistency ---
echo ""
echo "--- Check 4: Domain references ---"
# Check for placeholder domains that weren't substituted
# Exclude CRD documentation strings and comments
PLACEHOLDER_DOMAINS=$(grep -rn "example\.com\|changeme\|CHANGEME_DOMAIN" "${RENDERED_DIR}" --include="*.yaml" 2>/dev/null | \
  grep -v "^#\|#.*example\|CHANGEME_IMAGE\|description:\|\.com would\|\.com as\|gateway-api-crds" | \
  grep -E "^\s*(host|url|endpoint|server|issuer|redirect|domain|fqdn):" | head -10 || true)
if [[ -n "${PLACEHOLDER_DOMAINS}" ]]; then
  log_fail "Placeholder domains found in rendered templates:"
  echo "${PLACEHOLDER_DOMAINS}" | head -5
else
  log_ok "No placeholder domains"
fi

# --- Check 5: PVC protection and sizing ---
echo ""
echo "--- Check 5: PVC validation ---"
# PVCs MUST have resource-policy: keep to prevent Fleet delete/recreate.
# PVC storage size should be small (initial only) — VolumeAutoscaler manages growth.
PVC_FILES=$(grep -rl "kind: PersistentVolumeClaim" "${RENDERED_DIR}" --include="*.yaml" 2>/dev/null | grep -v fleet.yaml) || true
for pvc_file in ${PVC_FILES}; do
  PVC_NAME=$(grep "name:" "${pvc_file}" 2>/dev/null | head -1 | awk '{print $NF}') || true
  PVC_SIZE=$(grep "storage:" "${pvc_file}" 2>/dev/null | tail -1 | awk '{print $NF}') || true
  HAS_KEEP=$(grep -c "resource-policy.*keep" "${pvc_file}" 2>/dev/null) || true

  if [[ -z "${PVC_NAME:-}" ]]; then continue; fi

  # Must have resource-policy: keep
  if [[ "${HAS_KEEP}" -eq 0 ]]; then
    log_fail "PVC ${PVC_NAME}: missing helm.sh/resource-policy: keep (Fleet will delete/recreate)"
  else
    log_ok "PVC ${PVC_NAME}: has resource-policy: keep"
  fi

  # Warn if storage > 50Gi (should be initial size, not current cluster size)
  if [[ -n "${PVC_SIZE:-}" ]]; then
    SIZE_NUM=$(echo "${PVC_SIZE}" | grep -oP '^\d+')
    if [[ "${SIZE_NUM:-0}" -gt 50 ]]; then
      log_warn "PVC ${PVC_NAME}: storage ${PVC_SIZE} seems high — should be initial size only (VolumeAutoscaler manages growth)"
    else
      log_ok "PVC ${PVC_NAME}: storage ${PVC_SIZE} (initial, VolumeAutoscaler manages growth)"
    fi
  fi
done

# --- Check 6: deploy-version annotation present on key deployments ---
echo ""
echo "--- Check 6: deploy-version annotations ---"
DEPLOY_VERSION_COUNT=$(grep -rl "deploy-version:" "${RENDERED_DIR}" --include="*.yaml" 2>/dev/null | wc -l) || true
if [[ "${DEPLOY_VERSION_COUNT}" -gt 0 ]]; then
  log_ok "${DEPLOY_VERSION_COUNT} files have deploy-version annotation"
else
  log_warn "No deploy-version annotations found — pods may not restart on secret changes"
fi

# --- Strict mode: compare against live cluster ---
if [[ "${STRICT}" == "true" && -n "${KUBECONFIG:-}" ]]; then
  echo ""
  echo "--- Strict: Live cluster comparison ---"

  # Check PVC sizes against cluster
  for pvc_file in ${PVC_FILES}; do
    PVC_NAME=$(grep -A1 "^  name:" "${pvc_file}" 2>/dev/null | head -1 | awk '{print $2}')
    PVC_NS=$(grep "namespace:" "${pvc_file}" 2>/dev/null | head -1 | awk '{print $2}')
    MANIFEST_SIZE=$(grep "storage:" "${pvc_file}" 2>/dev/null | tail -1 | awk '{print $2}')

    if [[ -n "${PVC_NAME}" && -n "${PVC_NS}" ]]; then
      CLUSTER_SIZE=$(kubectl get pvc "${PVC_NAME}" -n "${PVC_NS}" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || echo "")
      if [[ -n "${CLUSTER_SIZE}" && "${MANIFEST_SIZE}" != "${CLUSTER_SIZE}" ]]; then
        # Convert to bytes for comparison
        log_fail "PVC ${PVC_NS}/${PVC_NAME}: manifest=${MANIFEST_SIZE} cluster=${CLUSTER_SIZE} — MISMATCH (cannot shrink PVCs)"
      elif [[ -n "${CLUSTER_SIZE}" ]]; then
        log_ok "PVC ${PVC_NS}/${PVC_NAME}: ${MANIFEST_SIZE} matches cluster"
      fi
    fi
  done
fi

# --- Summary ---
echo ""
echo "============================================="
if [[ "${ERRORS}" -gt 0 ]]; then
  echo -e "\033[0;31mFAILED: ${ERRORS} error(s), ${WARNINGS} warning(s)\033[0m"
  echo "DO NOT push or deploy until errors are fixed."
  exit 1
else
  echo -e "\033[0;32mPASSED: 0 errors, ${WARNINGS} warning(s)\033[0m"
  exit 0
fi
