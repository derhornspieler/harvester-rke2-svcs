#!/usr/bin/env bash
# detect-changed-groups.sh — Detect which Fleet bundle groups changed between commits.
#
# Usage:
#   detect-changed-groups.sh [before_sha] [after_sha]
#   detect-changed-groups.sh                          # defaults to HEAD~1..HEAD
#
# Output:
#   One group name per line, sorted in deploy order.
#   Outputs "ALL" if global files changed (scripts/, .env.example, lib/).
#
# Exit codes:
#   0 — changes detected (or ALL)
#   1 — no fleet-gitops changes detected

set -euo pipefail

BEFORE="${1:-${CI_COMMIT_BEFORE_SHA:-HEAD~1}}"
AFTER="${2:-${CI_COMMIT_SHA:-HEAD}}"

# Ordered list of bundle groups (deploy order matters)
GROUPS=(
  00-operators
  05-pki-secrets
  10-identity
  11-infra-auth
  15-dns
  20-monitoring
  30-harbor
  40-gitops
  50-gitlab
  60-cicd-onboard
)

# Get changed files under fleet-gitops/
CHANGED_FILES=$(git diff --name-only "${BEFORE}..${AFTER}" -- fleet-gitops/ 2>/dev/null || true)

if [[ -z "${CHANGED_FILES}" ]]; then
  exit 1
fi

# Global changes force full deploy
GLOBAL_PATTERNS="fleet-gitops/scripts/ fleet-gitops/.env"
for pattern in ${GLOBAL_PATTERNS}; do
  if echo "${CHANGED_FILES}" | grep -q "^${pattern}"; then
    echo "ALL"
    exit 0
  fi
done

# Map changed paths to group names
declare -A CHANGED_GROUPS
while IFS= read -r file; do
  # Extract group directory: fleet-gitops/<group>/...
  group=$(echo "${file}" | sed -n 's|^fleet-gitops/\([^/]*\)/.*|\1|p')
  if [[ -n "${group}" ]]; then
    CHANGED_GROUPS["${group}"]=1
  fi
done <<< "${CHANGED_FILES}"

# Output in deploy order
FOUND=0
for group in "${GROUPS[@]}"; do
  if [[ -n "${CHANGED_GROUPS[${group}]:-}" ]]; then
    echo "${group}"
    FOUND=1
  fi
done

if [[ "${FOUND}" -eq 0 ]]; then
  # Changes in fleet-gitops/ but not in any group directory (e.g., fleet.yaml at root)
  echo "ALL"
fi
