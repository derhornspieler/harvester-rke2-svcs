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
source "${SCRIPT_DIR}/lib/env-defaults.sh"

HARBOR="${HARBOR_HOST:?Set HARBOR_HOST in .env}"
HARBOR_USER="${HARBOR_USER:?Set HARBOR_USER in .env}"
HARBOR_PASS="${HARBOR_PASS:?Set HARBOR_PASS in .env}"

CHARTS=(
  # chart-name|repo-url|version
  "cert-manager|${HELM_REPO_CERT_MANAGER}|${CHART_VER_CERT_MANAGER}"
  "vault|${HELM_REPO_VAULT}|${CHART_VER_VAULT}"
  "external-secrets|${HELM_REPO_EXTERNAL_SECRETS}|${CHART_VER_EXTERNAL_SECRETS}"
  "cloudnative-pg|${HELM_REPO_CNPG}|${CHART_VER_CNPG}"
  "prometheus-operator-crds|${HELM_REPO_PROMETHEUS}|${CHART_VER_PROMETHEUS_CRDS}"
  "kube-prometheus-stack|${HELM_REPO_PROMETHEUS}|${CHART_VER_PROMETHEUS_STACK}"
  "harbor|${HELM_REPO_HARBOR}|${CHART_VER_HARBOR}"
  "gitlab|${HELM_REPO_GITLAB}|${CHART_VER_GITLAB}"
  "gitlab-runner|${HELM_REPO_GITLAB}|${CHART_VER_GITLAB_RUNNER}"
  "redis-operator|${HELM_REPO_REDIS_OPERATOR}|${CHART_VER_REDIS_OPERATOR}"
)

# OCI charts (already OCI, just re-tag to Harbor)
OCI_CHARTS=(
  # chart-name|oci-source|version
  "argo-cd|${OCI_SRC_ARGOCD}|${CHART_VER_ARGOCD}"
  "argo-rollouts|${OCI_SRC_ARGO_ROLLOUTS}|${CHART_VER_ARGO_ROLLOUTS}"
  "argo-workflows|${OCI_SRC_ARGO_WORKFLOWS}|${CHART_VER_ARGO_WORKFLOWS}"
  "keycloak-chart|${OCI_SRC_KEYCLOAKX}|${CHART_VER_KEYCLOAKX}"
)

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Login to Harbor OCI registry
log "Logging into Harbor OCI registry..."
echo "${HARBOR_PASS}" | helm registry login "${HARBOR}" \
  --username "${HARBOR_USER}" \
  --password-stdin 2>/dev/null

# Login to DHI OCI registry (Docker Hardened Images)
if [[ -n "${DHI_USER:-}" ]]; then
  log "Logging into DHI OCI registry..."
  echo "${DHI_PASS}" | helm registry login dhi.io \
    --username "${DHI_USER}" --password-stdin 2>/dev/null
fi

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

# Grafana plugins: push to Harbor as OCI artifact for air-gapped install
if [[ -n "${GRAFANA_PLUGIN_LOKIEXPLORE_FILE:-}" && "${GRAFANA_PLUGIN_LOKIEXPLORE_FILE}" != /* ]]; then
  GRAFANA_PLUGIN_LOKIEXPLORE_FILE="${FLEET_DIR}/${GRAFANA_PLUGIN_LOKIEXPLORE_FILE#./}"
fi
PLUGIN_FILE="${GRAFANA_PLUGIN_LOKIEXPLORE_FILE:-${FLEET_DIR}/plugins/grafana-lokiexplore-app-${GRAFANA_PLUGIN_LOKIEXPLORE_VER:-}.zip}"
if [[ -n "${GRAFANA_PLUGIN_LOKIEXPLORE_VER:-}" && -f "${PLUGIN_FILE}" ]]; then
  log "Pushing Grafana Logs Drilldown plugin to Harbor..."
  echo "${HARBOR_PASS}" | crane auth login "${HARBOR}" -u "${HARBOR_USER}" --password-stdin 2>/dev/null
  _plugin_tar="$(mktemp)"
  tar czf "${_plugin_tar}" -C "$(dirname "${PLUGIN_FILE}")" "$(basename "${PLUGIN_FILE}")"
  crane append -f "${_plugin_tar}" \
    -t "${HARBOR}/library/grafana-lokiexplore-app:${GRAFANA_PLUGIN_LOKIEXPLORE_VER}"
  rm -f "${_plugin_tar}"
  log "  Pushed ${HARBOR}/library/grafana-lokiexplore-app:${GRAFANA_PLUGIN_LOKIEXPLORE_VER}"
elif [[ -n "${GRAFANA_PLUGIN_LOKIEXPLORE_VER:-}" ]]; then
  log "WARN: GRAFANA_PLUGIN_LOKIEXPLORE_VER=${GRAFANA_PLUGIN_LOKIEXPLORE_VER} set but ${PLUGIN_FILE} not found — skipping"
fi

log "All charts pushed to oci://${HARBOR}/helm/"
