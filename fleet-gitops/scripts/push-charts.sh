#!/usr/bin/env bash
set -euo pipefail

# push-charts.sh — Pull upstream Helm charts and push to Harbor OCI registry
#
# Usage: ./push-charts.sh
#
# Prerequisites: helm CLI, Harbor credentials in .env (HARBOR_USER / HARBOR_PASS)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_DIR="$(dirname "${SCRIPT_DIR}")"

# Source .env for credentials
if [[ -f "${FLEET_DIR}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${FLEET_DIR}/.env"
  set +a
fi

HARBOR="harbor.aegisgroup.ch"
HARBOR_USER="${HARBOR_USER:?Set HARBOR_USER in .env}"
HARBOR_PASS="${HARBOR_PASS:?Set HARBOR_PASS in .env}"

CHARTS=(
  # chart-name|repo-url|version
  "cert-manager|https://charts.jetstack.io|v1.19.4"
  "vault|https://helm.releases.hashicorp.com|0.32.0"
  "external-secrets|https://charts.external-secrets.io|2.0.1"
  "cloudnative-pg|https://cloudnative-pg.github.io/charts|0.27.1"
  "prometheus-operator-crds|https://prometheus-community.github.io/helm-charts|27.0.0"
  "kube-prometheus-stack|https://prometheus-community.github.io/helm-charts|82.10.0"
  "harbor|https://helm.goharbor.io|1.18.2"
  "gitlab|https://charts.gitlab.io|9.9.2"
  "gitlab-runner|https://charts.gitlab.io|0.86.0"
  "redis-operator|https://ot-container-kit.github.io/helm-charts|0.23.0"
)

# OCI charts (already OCI, just re-tag to Harbor)
OCI_CHARTS=(
  # chart-name|oci-source|version
  "argo-cd|oci://ghcr.io/argoproj/argo-helm/argo-cd|9.4.7"
  "argo-rollouts|oci://ghcr.io/argoproj/argo-helm/argo-rollouts|2.40.6"
  "argo-workflows|oci://ghcr.io/argoproj/argo-helm/argo-workflows|0.47.4"
)

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Login to Harbor OCI registry
log "Logging into Harbor OCI registry..."
echo "${HARBOR_PASS}" | helm registry login "${HARBOR}" \
  --username "${HARBOR_USER}" \
  --password-stdin 2>/dev/null

# Repo-based charts: add repo, pull, push
for entry in "${CHARTS[@]}"; do
  IFS='|' read -r name repo version <<< "${entry}"
  log "Processing ${name}:${version}..."
  helm repo add "${name%%/*}" "${repo}" --force-update 2>/dev/null || true
  helm repo update "${name%%/*}" 2>/dev/null || true
  helm pull "${name}" --repo "${repo}" --version "${version}"
  helm push "${name}-${version}.tgz" "oci://${HARBOR}/helm/"
  rm -f "${name}-${version}.tgz"
  log "  Pushed oci://${HARBOR}/helm/${name}:${version}"
done

# OCI charts: pull from source, push to Harbor
for entry in "${OCI_CHARTS[@]}"; do
  IFS='|' read -r name source version <<< "${entry}"
  log "Processing ${name}:${version} (OCI)..."
  helm pull "${source}" --version "${version}"
  helm push "${name}-${version}.tgz" "oci://${HARBOR}/helm/"
  rm -f "${name}-${version}.tgz"
  log "  Pushed oci://${HARBOR}/helm/${name}:${version}"
done

log "All charts pushed to oci://${HARBOR}/helm/"
