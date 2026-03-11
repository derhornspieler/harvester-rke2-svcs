# Fleet GitOps Environment Externalization Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove ALL hardcoded environment-specific values (domains, IPs, certs, chart versions, cluster names, images) from fleet-gitops/ and source them from a single `.env` file.

**Architecture:** Manifests become templates with `${VAR}` placeholders. A new `render-templates.sh` preprocessing step reads `.env` and runs `envsubst` on all manifests before `push-bundles.sh` packages them. Scripts consume `.env` variables directly. The `.env.example` (already created) documents every variable.

**Tech Stack:** Bash, envsubst, Helm OCI, Rancher Fleet HelmOps

---

## Design Decisions

### Why envsubst (not Helm templating)?

The raw-manifest bundles in `manifests/` directories are plain YAML — they don't use Helm template syntax. Converting 200+ manifests to `{{ .Values.x }}` would be a massive rewrite and would break the current push-bundles.sh packaging. Instead:

1. Replace hardcoded values with `${VAR_NAME}` tokens in source manifests
2. `render-templates.sh` runs envsubst to produce rendered manifests
3. `push-bundles.sh` packages the rendered output (unchanged workflow)

envsubst is given an explicit variable list to prevent accidental substitution of `$` characters in embedded shell scripts (vault-init-job, keycloak-config-job, etc.).

### What stays hardcoded (by design)?

- **Namespace names in `metadata.namespace:`** — These are structural K8s requirements, tightly coupled to the deployment architecture. Changing them would require updating every cross-namespace reference, RBAC binding, and Fleet target. Not worth parameterizing.
- **Vault KV paths** (`kv/services/*`, `kv/oidc/*`) — These are architectural conventions, not environment-specific. The Vault *URL* is parameterized, but the path structure is stable.
- **CRD names** — Standard upstream CRD names in cleanup functions.
- **Kubernetes internal DNS patterns** (`*.svc.cluster.local`) — These follow K8s conventions. The service name and namespace portions are already determined by namespace and release names.

### Derived variables

Many FQDNs are derived from `DOMAIN`:
- `KEYCLOAK_FQDN` defaults to `keycloak.${DOMAIN}` unless overridden
- `OIDC_ISSUER_URL` defaults to `https://${KEYCLOAK_FQDN}/realms/${KEYCLOAK_REALM}`
- TLS secret names are derived from FQDN: `${FQDN//./-}-tls`

This keeps `.env` lean while allowing full override flexibility.

---

## File Map

### New files
| File | Purpose |
|------|---------|
| `fleet-gitops/.env.example` | All variables documented (ALREADY CREATED) |
| `fleet-gitops/scripts/render-templates.sh` | envsubst preprocessor — renders templates → rendered/ |
| `fleet-gitops/scripts/lib/env-defaults.sh` | Computes derived variables (FQDNs, OIDC URLs, TLS secret names) |

### Modified files — Scripts (4 files)
| File | Changes |
|------|---------|
| `fleet-gitops/scripts/deploy-fleet-helmops.sh` | Use env vars for HARBOR, chart versions, cluster name |
| `fleet-gitops/scripts/push-charts.sh` | Use env vars for HARBOR, chart versions, repo URLs |
| `fleet-gitops/scripts/push-bundles.sh` | Use env vars for HARBOR; read from rendered/ output |
| `fleet-gitops/scripts/deploy.sh` | Use env vars for HARBOR, DOMAIN, TRAEFIK_LB_IP |

### Modified files — Manifests (~60 files with hardcoded values)
Every file containing `example.com`, hardcoded IPs, inline PEM certs, or hardcoded image references. Organized by bundle group below.

### Modified files — fleet.yaml (30+ files)
Every `fleet.yaml` with `oci://harbor.example.com` and `clusterName: rke2-prod`.

### Modified files — values.yaml (8 files)
Helm values files with hardcoded domains, OIDC URLs, database hosts, image references.

---

## Chunk 1: Foundation — Scripts & Rendering Pipeline

### Task 1: Create env-defaults.sh (derived variable computation)

**Files:**
- Create: `fleet-gitops/scripts/lib/env-defaults.sh`

- [ ] **Step 1: Create the lib directory and env-defaults.sh**

```bash
#!/usr/bin/env bash
# env-defaults.sh — Compute derived variables from .env base values
# Sourced by render-templates.sh and other scripts AFTER .env is loaded

# Require base variables
: "${DOMAIN:?DOMAIN must be set in .env}"
: "${HARBOR_HOST:?HARBOR_HOST must be set in .env}"
: "${KEYCLOAK_REALM:=platform}"

# --- Derived FQDNs (override in .env if non-standard) ---
export KEYCLOAK_FQDN="${KEYCLOAK_FQDN:-keycloak.${DOMAIN}}"
export VAULT_FQDN="${VAULT_FQDN:-vault.${DOMAIN}}"
export GITLAB_FQDN="${GITLAB_FQDN:-gitlab.${DOMAIN}}"
export KAS_FQDN="${KAS_FQDN:-kas.${DOMAIN}}"
export ARGOCD_FQDN="${ARGOCD_FQDN:-argo.${DOMAIN}}"
export ROLLOUTS_FQDN="${ROLLOUTS_FQDN:-rollouts.${DOMAIN}}"
export WORKFLOWS_FQDN="${WORKFLOWS_FQDN:-workflows.${DOMAIN}}"
export GRAFANA_FQDN="${GRAFANA_FQDN:-grafana.${DOMAIN}}"
export PROMETHEUS_FQDN="${PROMETHEUS_FQDN:-prometheus.${DOMAIN}}"
export ALERTMANAGER_FQDN="${ALERTMANAGER_FQDN:-alertmanager.${DOMAIN}}"
export HUBBLE_FQDN="${HUBBLE_FQDN:-hubble.${DOMAIN}}"
export TRAEFIK_FQDN="${TRAEFIK_FQDN:-traefik.${DOMAIN}}"
export HARBOR_FQDN="${HARBOR_FQDN:-${HARBOR_HOST}}"

# --- Derived OIDC URLs ---
export OIDC_ISSUER_URL="${OIDC_ISSUER_URL:-https://${KEYCLOAK_FQDN}/realms/${KEYCLOAK_REALM}}"

# --- Derived TLS secret names (dots → dashes, append -tls) ---
export KEYCLOAK_TLS_SECRET="${KEYCLOAK_FQDN//./-}-tls"
export VAULT_TLS_SECRET="${VAULT_FQDN//./-}-tls"
export GITLAB_TLS_SECRET="${GITLAB_FQDN//./-}-tls"
export KAS_TLS_SECRET="${KAS_FQDN//./-}-tls"
export ARGOCD_TLS_SECRET="${ARGOCD_FQDN//./-}-tls"
export ROLLOUTS_TLS_SECRET="${ROLLOUTS_FQDN//./-}-tls"
export WORKFLOWS_TLS_SECRET="${WORKFLOWS_FQDN//./-}-tls"
export GRAFANA_TLS_SECRET="${GRAFANA_FQDN//./-}-tls"
export PROMETHEUS_TLS_SECRET="${PROMETHEUS_FQDN//./-}-tls"
export ALERTMANAGER_TLS_SECRET="${ALERTMANAGER_FQDN//./-}-tls"
export HUBBLE_TLS_SECRET="${HUBBLE_FQDN//./-}-tls"
export TRAEFIK_TLS_SECRET="${TRAEFIK_FQDN//./-}-tls"
export HARBOR_TLS_SECRET="${HARBOR_FQDN//./-}-tls"

# --- Derived GitLab URL ---
export GITLAB_URL="${GITLAB_URL:-https://${GITLAB_FQDN}}"

# --- Harbor OCI prefixes ---
export OCI_HELM_PREFIX="oci://${HARBOR_HOST}/helm"
export OCI_FLEET_PREFIX="oci://${HARBOR_HOST}/fleet"

# --- Vault PKI role (domain with dots replaced by -dot-) ---
export VAULT_PKI_ROLE="${VAULT_PKI_ROLE:-pki_int/sign/${DOMAIN//./-dot-}}"

# --- Root CA cert content (read from file if provided) ---
if [[ -n "${ROOT_CA_PEM_FILE:-}" && -f "${ROOT_CA_PEM_FILE}" ]]; then
  export ROOT_CA_PEM_CONTENT
  ROOT_CA_PEM_CONTENT="$(cat "${ROOT_CA_PEM_FILE}")"
  # Base64-encoded version (for K8s Secrets)
  export ROOT_CA_PEM_B64
  ROOT_CA_PEM_B64="$(base64 -w0 < "${ROOT_CA_PEM_FILE}")"
  # Indented versions for YAML embedding (2-space, 4-space, 8-space)
  export ROOT_CA_PEM_INDENT2
  ROOT_CA_PEM_INDENT2="$(sed 's/^/  /' "${ROOT_CA_PEM_FILE}")"
  export ROOT_CA_PEM_INDENT4
  ROOT_CA_PEM_INDENT4="$(sed 's/^/    /' "${ROOT_CA_PEM_FILE}")"
  export ROOT_CA_PEM_INDENT8
  ROOT_CA_PEM_INDENT8="$(sed 's/^/        /' "${ROOT_CA_PEM_FILE}")"
fi

# --- Admin email ---
export PLATFORM_ADMIN_EMAIL="${PLATFORM_ADMIN_EMAIL:-admin@${DOMAIN}}"

# --- ENVSUBST variable list (explicit, to avoid clobbering $VAR in shell scripts) ---
# This is the list of ALL variables that render-templates.sh will substitute.
# Any $VAR not in this list is left as-is (critical for embedded bash in Jobs).
export ENVSUBST_VARS='${DOMAIN} ${HARBOR_HOST} ${HARBOR_FQDN}
${KEYCLOAK_FQDN} ${KEYCLOAK_TLS_SECRET} ${KEYCLOAK_REALM}
${VAULT_FQDN} ${VAULT_TLS_SECRET}
${GITLAB_FQDN} ${GITLAB_TLS_SECRET} ${GITLAB_URL}
${KAS_FQDN} ${KAS_TLS_SECRET}
${ARGOCD_FQDN} ${ARGOCD_TLS_SECRET}
${ROLLOUTS_FQDN} ${ROLLOUTS_TLS_SECRET}
${WORKFLOWS_FQDN} ${WORKFLOWS_TLS_SECRET}
${GRAFANA_FQDN} ${GRAFANA_TLS_SECRET}
${PROMETHEUS_FQDN} ${PROMETHEUS_TLS_SECRET}
${ALERTMANAGER_FQDN} ${ALERTMANAGER_TLS_SECRET}
${HUBBLE_FQDN} ${HUBBLE_TLS_SECRET}
${TRAEFIK_FQDN} ${TRAEFIK_TLS_SECRET}
${HARBOR_TLS_SECRET}
${OIDC_ISSUER_URL}
${FLEET_TARGET_CLUSTER} ${FLEET_NAMESPACE}
${TRAEFIK_LB_IP} ${DNS_SERVER_IP} ${DNS_ZONE}
${TSIG_KEY_NAME}
${S3_REGION} ${STORAGE_CLASS} ${GATEWAY_CLASS}
${VAULT_INTERNAL_URL} ${MINIO_INTERNAL_URL}
${PROMETHEUS_INTERNAL_URL} ${LOKI_INTERNAL_URL}
${KEYCLOAK_INTERNAL_URL}
${KEYCLOAK_DB_HOST} ${KEYCLOAK_DB_NAME}
${GRAFANA_DB_HOST} ${GRAFANA_DB_NAME}
${HARBOR_DB_HOST} ${HARBOR_DB_NAME}
${GITLAB_DB_HOST_RW} ${GITLAB_DB_HOST_RO} ${GITLAB_DB_NAME}
${REDIS_MASTER_NAME}
${HARBOR_REDIS_SENTINEL} ${GITLAB_REDIS_SENTINEL}
${VAULT_PKI_ROLE}
${RBAC_GROUP_ADMINS} ${RBAC_GROUP_INFRA} ${RBAC_GROUP_NETWORK}
${RBAC_GROUP_SENIOR_DEVS} ${RBAC_GROUP_DEVS}
${PLATFORM_ADMIN_USER} ${PLATFORM_ADMIN_EMAIL}
${IMAGE_ALPINE_K8S} ${IMAGE_CURL} ${IMAGE_KEYCLOAK}
${IMAGE_POSTGRESQL_17} ${IMAGE_POSTGRESQL_16}
${IMAGE_REDIS} ${IMAGE_REDIS_SENTINEL} ${IMAGE_REDIS_EXPORTER}
${IMAGE_MINIO} ${IMAGE_MINIO_MC}
${IMAGE_LOKI} ${IMAGE_ALLOY} ${IMAGE_OAUTH2_PROXY}
${IMAGE_NODE_LABELER} ${IMAGE_STORAGE_AUTOSCALER} ${IMAGE_CLUSTER_AUTOSCALER}
${IMAGE_VAULT} ${IMAGE_VALKEY} ${IMAGE_HAPROXY}
${MINIO_BUCKET_HARBOR} ${MINIO_BUCKET_CNPG_BACKUPS}
${MINIO_BUCKET_GITLAB_LFS} ${MINIO_BUCKET_GITLAB_ARTIFACTS}
${MINIO_BUCKET_GITLAB_UPLOADS} ${MINIO_BUCKET_GITLAB_PACKAGES}
${MINIO_BUCKET_GITLAB_PAGES}
${OCI_HELM_PREFIX} ${OCI_FLEET_PREFIX}
${CHART_VER_CERT_MANAGER} ${CHART_VER_VAULT} ${CHART_VER_EXTERNAL_SECRETS}
${CHART_VER_CNPG} ${CHART_VER_REDIS_OPERATOR} ${CHART_VER_EXTERNAL_DNS}
${CHART_VER_PROMETHEUS_CRDS} ${CHART_VER_PROMETHEUS_STACK}
${CHART_VER_HARBOR} ${CHART_VER_ARGOCD} ${CHART_VER_ARGO_ROLLOUTS}
${CHART_VER_ARGO_WORKFLOWS} ${CHART_VER_GITLAB} ${CHART_VER_GITLAB_RUNNER}
${ROOT_CA_PEM_CONTENT} ${ROOT_CA_PEM_B64}
${ROOT_CA_PEM_INDENT2} ${ROOT_CA_PEM_INDENT4} ${ROOT_CA_PEM_INDENT8}
${HARBOR_EXTERNAL_URL}'
```

- [ ] **Step 2: Verify it sources correctly**

```bash
cd fleet-gitops && source .env && source scripts/lib/env-defaults.sh && echo "KEYCLOAK_FQDN=${KEYCLOAK_FQDN}"
```

Expected: `KEYCLOAK_FQDN=keycloak.example.com` (or whatever DOMAIN is)

- [ ] **Step 3: Commit**

```bash
git add fleet-gitops/scripts/lib/env-defaults.sh
git commit -m "feat: add env-defaults.sh for derived variable computation"
```

---

### Task 2: Create render-templates.sh

**Files:**
- Create: `fleet-gitops/scripts/render-templates.sh`

- [ ] **Step 1: Create render-templates.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

# render-templates.sh — Render fleet-gitops templates with environment variables
#
# Reads .env, computes derived variables, then runs envsubst on all YAML
# files in manifests/ directories and fleet.yaml / values.yaml files.
#
# Output: fleet-gitops/rendered/ (mirrors source structure)
#
# Usage:
#   ./render-templates.sh              # Render all bundles
#   ./render-templates.sh --check      # Dry run: show what would change
#   ./render-templates.sh --diff       # Show diff between source and rendered

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_DIR="$(dirname "${SCRIPT_DIR}")"
RENDERED_DIR="${FLEET_DIR}/rendered"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
die()       { log_error "$*"; exit 1; }

# --- Load environment ---
env_file="${FLEET_DIR}/.env"
[[ -f "${env_file}" ]] || die ".env file not found at ${env_file}. Copy .env.example to .env and fill in values."

set -a
# shellcheck source=/dev/null
source "${env_file}"
set +a

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/env-defaults.sh"

# --- Argument parsing ---
CHECK_MODE=false
DIFF_MODE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_MODE=true; shift ;;
    --diff)  DIFF_MODE=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--check] [--diff]"
      echo "  --check  Show what files would be rendered (dry run)"
      echo "  --diff   Show diff between source templates and rendered output"
      exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# --- Collect files to render ---
# All YAML files in the bundle directories (manifests/, fleet.yaml, values.yaml)
mapfile -t TEMPLATE_FILES < <(find "${FLEET_DIR}" \
  -path "${RENDERED_DIR}" -prune -o \
  -path "${FLEET_DIR}/scripts" -prune -o \
  -path "${FLEET_DIR}/.git" -prune -o \
  \( -name "*.yaml" -o -name "*.yml" \) -print | sort)

if [[ "${CHECK_MODE}" == true ]]; then
  log_info "Files that would be rendered (${#TEMPLATE_FILES[@]} total):"
  printf '%s\n' "${TEMPLATE_FILES[@]}" | sed "s|${FLEET_DIR}/||"
  exit 0
fi

# --- Render ---
rm -rf "${RENDERED_DIR}"
rendered=0
unchanged=0

for src in "${TEMPLATE_FILES[@]}"; do
  rel="${src#"${FLEET_DIR}/"}"
  dest="${RENDERED_DIR}/${rel}"
  dest_dir="$(dirname "${dest}")"
  mkdir -p "${dest_dir}"

  # Run envsubst with explicit variable list (preserves $VAR in embedded shell scripts)
  envsubst "${ENVSUBST_VARS}" < "${src}" > "${dest}"

  if [[ "${DIFF_MODE}" == true ]]; then
    if ! diff -q "${src}" "${dest}" > /dev/null 2>&1; then
      echo -e "\n${YELLOW}--- ${rel} ---${NC}"
      diff --color=always -u "${src}" "${dest}" || true
      rendered=$((rendered + 1))
    else
      unchanged=$((unchanged + 1))
    fi
  else
    rendered=$((rendered + 1))
  fi
done

if [[ "${DIFF_MODE}" == true ]]; then
  log_info "${rendered} files changed, ${unchanged} unchanged"
else
  log_ok "Rendered ${rendered} files to ${RENDERED_DIR}/"
fi
```

- [ ] **Step 2: Make executable and test**

```bash
chmod +x fleet-gitops/scripts/render-templates.sh
fleet-gitops/scripts/render-templates.sh --check
```

Expected: Lists all YAML files that would be rendered.

- [ ] **Step 3: Add rendered/ to .gitignore**

Add `rendered/` to `fleet-gitops/.gitignore`.

- [ ] **Step 4: Commit**

```bash
git add fleet-gitops/scripts/render-templates.sh fleet-gitops/.gitignore
git commit -m "feat: add render-templates.sh envsubst preprocessor"
```

---

### Task 3: Update push-bundles.sh to use rendered/ output

**Files:**
- Modify: `fleet-gitops/scripts/push-bundles.sh`

- [ ] **Step 1: Replace HARBOR hardcode and add render step**

In push-bundles.sh, change:
- Line 27: `HARBOR="harbor.example.com"` → `HARBOR="${HARBOR_HOST:?Set HARBOR_HOST in .env}"`
- Line 30: `OCI_REGISTRY="oci://${HARBOR}/fleet"` → `OCI_REGISTRY="oci://${HARBOR_HOST}/fleet"`
- Line 5 comment: Replace `oci://harbor.example.com/fleet/` → `oci://<HARBOR_HOST>/fleet/`
- In `push_bundle()` function: Change `bundle_dir` to read from `rendered/` if available, falling back to source

Specifically, after sourcing .env, add:
```bash
# Source derived variables
source "${SCRIPT_DIR}/lib/env-defaults.sh"

# Render templates before packaging
log "Rendering templates..."
"${SCRIPT_DIR}/render-templates.sh"
```

And change `push_bundle()` to read from rendered/:
```bash
local bundle_dir="${FLEET_DIR}/rendered/${bundle_relpath}"
```

- [ ] **Step 2: Test push-bundles.sh --help still works**

- [ ] **Step 3: Commit**

```bash
git add fleet-gitops/scripts/push-bundles.sh
git commit -m "refactor: push-bundles.sh uses .env vars and rendered templates"
```

---

### Task 4: Update push-charts.sh to use .env chart versions

**Files:**
- Modify: `fleet-gitops/scripts/push-charts.sh`

- [ ] **Step 1: Replace all hardcoded values**

Replace HARBOR and chart version hardcodes:
```bash
HARBOR="${HARBOR_HOST:?Set HARBOR_HOST in .env}"

# Source derived variables
source "${SCRIPT_DIR}/lib/env-defaults.sh"

CHARTS=(
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

OCI_CHARTS=(
  "argo-cd|${OCI_SRC_ARGOCD}|${CHART_VER_ARGOCD}"
  "argo-rollouts|${OCI_SRC_ARGO_ROLLOUTS}|${CHART_VER_ARGO_ROLLOUTS}"
  "argo-workflows|${OCI_SRC_ARGO_WORKFLOWS}|${CHART_VER_ARGO_WORKFLOWS}"
)
```

- [ ] **Step 2: Commit**

```bash
git add fleet-gitops/scripts/push-charts.sh
git commit -m "refactor: push-charts.sh uses .env for chart versions and repos"
```

---

### Task 5: Update deploy-fleet-helmops.sh to use .env

**Files:**
- Modify: `fleet-gitops/scripts/deploy-fleet-helmops.sh`

- [ ] **Step 1: Replace HARBOR hardcode**

Line 32: `HARBOR="harbor.example.com"` → `HARBOR="${HARBOR_HOST:?Set HARBOR_HOST in .env}"`

- [ ] **Step 2: Source env-defaults.sh after .env**

After the existing `.env` source block, add:
```bash
source "${SCRIPT_DIR}/lib/env-defaults.sh"
```

- [ ] **Step 3: Replace hardcoded chart versions in HELMOP_DEFS**

Replace every hardcoded version with its env var:
- `27.0.0` → `${CHART_VER_PROMETHEUS_CRDS}`
- `0.27.1` → `${CHART_VER_CNPG}`
- `0.23.0` → `${CHART_VER_REDIS_OPERATOR}`
- `v1.19.4` → `${CHART_VER_CERT_MANAGER}`
- `0.32.0` → `${CHART_VER_VAULT}`
- `2.0.1` → `${CHART_VER_EXTERNAL_SECRETS}`
- `82.10.0` → `${CHART_VER_PROMETHEUS_STACK}`
- `1.18.2` → `${CHART_VER_HARBOR}`
- `9.4.7` → `${CHART_VER_ARGOCD}`
- `2.40.6` → `${CHART_VER_ARGO_ROLLOUTS}`
- `0.47.4` → `${CHART_VER_ARGO_WORKFLOWS}`
- `9.9.2` → `${CHART_VER_GITLAB}`
- `0.86.0` → `${CHART_VER_GITLAB_RUNNER}`

- [ ] **Step 4: Replace hardcoded cluster name**

Line 197, 256, 363, 366: `rke2-prod` → `${FLEET_TARGET_CLUSTER}`
Line 242, 256: `fleet-default` → `${FLEET_NAMESPACE}`

- [ ] **Step 5: Fix build_helmop_cr to use env vars**

In `build_helmop_cr()`, line 242: `"fleet-default"` → `"${FLEET_NAMESPACE}"`
Line 256: `"rke2-prod"` → `"${FLEET_TARGET_CLUSTER}"`

- [ ] **Step 6: Replace HelmOp values.yaml paths to read from rendered/**

When HELMOP_DEFS references `values_file`, change the path resolution to read from `rendered/` if available:
```bash
local values_path="${FLEET_DIR}/rendered/${values_file_rel}"
if [[ ! -f "${values_path}" ]]; then
  values_path="${FLEET_DIR}/${values_file_rel}"
fi
```

- [ ] **Step 7: Update comments**

Lines 17-18: Replace `harbor.example.com` in comments with `<HARBOR_HOST>`.

- [ ] **Step 8: Commit**

```bash
git add fleet-gitops/scripts/deploy-fleet-helmops.sh
git commit -m "refactor: deploy-fleet-helmops.sh uses .env for all environment values"
```

---

### Task 6: Update deploy.sh to use .env

**Files:**
- Modify: `fleet-gitops/scripts/deploy.sh`

- [ ] **Step 1: Replace hardcodes**

- Line 36: `HARBOR="harbor.example.com"` → `HARBOR="${HARBOR_HOST:?Set HARBOR_HOST in .env}"`
- Line 231: `192.168.48.2` → `${TRAEFIK_LB_IP}`
- Line 386: `"example.com"` → `"${DOMAIN}"`
- Lines 111, 187-188: `rke2-prod` → `${FLEET_TARGET_CLUSTER}`
- Line 188: `fleet-default` → `${FLEET_NAMESPACE}`

- [ ] **Step 2: Source env-defaults.sh**

- [ ] **Step 3: Commit**

```bash
git add fleet-gitops/scripts/deploy.sh
git commit -m "refactor: deploy.sh uses .env for domain, IPs, and cluster name"
```

---

## Chunk 2: Bundle Group 00-operators

### Task 7: Templatize 00-operators fleet.yaml files

**Files to modify** (replace `harbor.example.com` with `${HARBOR_HOST}` and `rke2-prod` with `${FLEET_TARGET_CLUSTER}`):
- `fleet-gitops/00-operators/cnpg-operator/fleet.yaml`
- `fleet-gitops/00-operators/redis-operator/fleet.yaml`
- `fleet-gitops/00-operators/node-labeler/fleet.yaml`
- `fleet-gitops/00-operators/storage-autoscaler/fleet.yaml`
- `fleet-gitops/00-operators/cluster-autoscaler/fleet.yaml`
- `fleet-gitops/00-operators/gateway-api-crds/fleet.yaml`
- `fleet-gitops/00-operators/fleet.yaml`

- [ ] **Step 1: For each fleet.yaml, replace:**
  - `oci://harbor.example.com/helm/` → `${OCI_HELM_PREFIX}/`
  - `oci://harbor.example.com/fleet/` → `${OCI_FLEET_PREFIX}/`
  - `clusterName: rke2-prod` → `clusterName: ${FLEET_TARGET_CLUSTER}`
  - Chart version strings → `${CHART_VER_*}` env vars

- [ ] **Step 2: Templatize container images in manifests**
  - `00-operators/node-labeler/manifests/deployment.yaml` line 48: `harbor.example.com/library/node-labeler:v0.2.0` → `${IMAGE_NODE_LABELER}`
  - `00-operators/storage-autoscaler/manifests/deployment.yaml` line 48: `harbor.example.com/library/storage-autoscaler:v0.2.0` → `${IMAGE_STORAGE_AUTOSCALER}`
  - `00-operators/cluster-autoscaler/manifests/deployment.yaml` line 54: `registry.k8s.io/autoscaling/cluster-autoscaler:v1.34.3` → `${IMAGE_CLUSTER_AUTOSCALER}`

- [ ] **Step 3: Test render**

```bash
fleet-gitops/scripts/render-templates.sh --diff 2>&1 | grep "00-operators"
```

- [ ] **Step 4: Commit**

```bash
git add fleet-gitops/00-operators/
git commit -m "refactor: templatize 00-operators bundle group"
```

---

## Chunk 3: Bundle Group 05-pki-secrets

### Task 8: Templatize 05-pki-secrets

**Files to modify:**
- All `fleet.yaml` files in 05-pki-secrets/
- `05-pki-secrets/vault/values.yaml` — storage class, image
- `05-pki-secrets/vault-pki-issuer/manifests/cluster-issuer.yaml` — Vault PKI role with domain
- `05-pki-secrets/vault-init/manifests/vault-init-job.yaml` — DOMAIN, image, Vault PKI role
- `05-pki-secrets/vault-unsealer/manifests/vault-unsealer.yaml` — image
- `05-pki-secrets/cert-manager/values.yaml` (if any hardcodes)
- `05-pki-secrets/external-secrets/values.yaml` (if any hardcodes)

- [ ] **Step 1: fleet.yaml files** — same pattern as Task 7

- [ ] **Step 2: vault/values.yaml**
  - `storageClass: "harvester"` → `storageClass: "${STORAGE_CLASS}"`
  - Image `hashicorp/vault:1.21.2` → `${IMAGE_VAULT}`

- [ ] **Step 3: vault-pki-issuer/manifests/cluster-issuer.yaml**
  - `pki_int/sign/aegisgroup-dot-ch` → `${VAULT_PKI_ROLE}`
  - `http://vault.vault.svc.cluster.local:8200` → `${VAULT_INTERNAL_URL}`

- [ ] **Step 4: vault-init-job.yaml**
  - `DOMAIN="example.com"` → `DOMAIN="${DOMAIN}"`
  - `docker.io/alpine/k8s:1.32.4` → `${IMAGE_ALPINE_K8S}`

  **CRITICAL**: This file contains extensive embedded bash. The envsubst explicit variable list in env-defaults.sh ensures only our named variables are substituted. Shell variables like `$VAULT_TOKEN`, `$DOMAIN`, etc. inside the job's `command:` block will NOT be touched because they're not in the ENVSUBST_VARS list — EXCEPT `$DOMAIN` which IS in our list. For the vault-init-job, the `DOMAIN=` assignment inside the job script must use a different approach:
  - Replace `DOMAIN="example.com"` in the env block (line ~85) with `DOMAIN="${DOMAIN}"` — envsubst will substitute this to the actual value at render time. The subsequent usage of `$DOMAIN` inside the script block won't be touched because envsubst only replaces `${DOMAIN}` (with braces), not `$DOMAIN` (without braces).

  Wait — actually envsubst replaces BOTH `${DOMAIN}` and `$DOMAIN`. This means we need a different approach for files with embedded shell scripts.

  **Revised approach for Job manifests**: Use a unique token prefix instead of shell-style variables. Use `__DOMAIN__` style tokens and a sed-based replacement, OR use envsubst but escape the internal `$DOMAIN` references as `$$DOMAIN` which envsubst leaves as `$DOMAIN`.

  **Simplest approach**: In Job manifests that contain embedded bash, use `CHANGEME_DOMAIN` style tokens that are distinct from shell variable syntax. The render script does `sed` replacements for `CHANGEME_*` tokens.

  Actually, the cleanest approach: Don't template Job manifests at all. Instead, have the Job scripts read their config from environment variables or ConfigMaps that are already set by the cluster. The vault-init-job already has `DOMAIN="example.com"` as a variable assignment at the top of its script — we just need to change that one assignment.

  **Final decision**: For Job manifests with embedded bash:
  1. Only template the `env:` section (container environment variables), NOT the `command:` script body
  2. Move hardcoded values like `DOMAIN="example.com"` to `env:` blocks: `- name: DOMAIN; value: "${DOMAIN}"`
  3. The script body already references `$DOMAIN` — it will pick up the value from the container env
  4. For the `image:` field, use `${IMAGE_ALPINE_K8S}` directly (no conflict)

- [ ] **Step 5: vault-unsealer.yaml**
  - `docker.io/alpine/k8s:1.32.4` → `${IMAGE_ALPINE_K8S}`

- [ ] **Step 6: Test render and verify no broken shell scripts**

```bash
fleet-gitops/scripts/render-templates.sh --diff 2>&1 | grep "05-pki"
# Manually inspect vault-init-job to ensure embedded bash is intact
```

- [ ] **Step 7: Commit**

```bash
git add fleet-gitops/05-pki-secrets/
git commit -m "refactor: templatize 05-pki-secrets bundle group"
```

---

## Chunk 4: Bundle Group 10-identity

### Task 9: Templatize 10-identity

**Files to modify:**
- All `fleet.yaml` files
- `10-identity/keycloak/manifests/deployment.yaml` — image, DB host, FQDN
- `10-identity/keycloak/manifests/gateway.yaml` — FQDN, TLS secret
- `10-identity/keycloak/manifests/httproute.yaml` — FQDN
- `10-identity/keycloak/manifests/secretstore.yaml` — Vault URL
- `10-identity/cnpg-keycloak/manifests/keycloak-pg-cluster.yaml` — image, storage class, MinIO URL
- `10-identity/cnpg-keycloak/manifests/secretstore.yaml` — Vault URL
- `10-identity/keycloak-config/manifests/keycloak-config-job.yaml` — DOMAIN, image, RBAC groups, admin user
- `10-identity/keycloak-ldap-federation/manifests/keycloak-ldap-federation-job.yaml` — DOMAIN, image

- [ ] **Step 1: fleet.yaml files** — same OCI/cluster pattern

- [ ] **Step 2: keycloak deployment.yaml**
  - `quay.io/keycloak/keycloak:26.0.8` → `${IMAGE_KEYCLOAK}`
  - `keycloak-pg-rw.database.svc.cluster.local` → `${KEYCLOAK_DB_HOST}`
  - `keycloak-headless.keycloak.svc.cluster.local` — leave as-is (internal to keycloak namespace)

- [ ] **Step 3: keycloak gateway.yaml + httproute.yaml**
  - `keycloak.example.com` → `${KEYCLOAK_FQDN}`
  - `keycloak-aegisgroup-ch-tls` → `${KEYCLOAK_TLS_SECRET}`
  - `gatewayClassName: traefik` → `gatewayClassName: ${GATEWAY_CLASS}`

- [ ] **Step 4: SecretStore files** — `http://vault.vault.svc.cluster.local:8200` → `${VAULT_INTERNAL_URL}`

- [ ] **Step 5: CNPG cluster** — image, storage class, MinIO URL, bucket name

- [ ] **Step 6: keycloak-config-job.yaml** (embedded bash — use env: block approach)
  - Move `DOMAIN="example.com"` to container `env:` section
  - Move RBAC group names to `env:` section
  - Move admin user to `env:` section
  - `docker.io/alpine/k8s:1.32.4` → `${IMAGE_ALPINE_K8S}`

- [ ] **Step 7: keycloak-ldap-federation-job.yaml** — same env: block approach

- [ ] **Step 8: Commit**

```bash
git add fleet-gitops/10-identity/
git commit -m "refactor: templatize 10-identity bundle group"
```

---

## Chunk 5: Bundle Group 15-dns

### Task 10: Templatize 15-dns

**Files to modify:**
- `15-dns/external-dns/fleet.yaml`
- `15-dns/external-dns/values.yaml` — domain, DNS server IP, TSIG key
- `15-dns/external-dns-secrets/fleet.yaml`
- `15-dns/external-dns-secrets/manifests/push-secret.yaml` — TSIG key name (fix inconsistency!)
- `15-dns/external-dns-secrets/manifests/external-dns-secrets.yaml` — Vault URL

- [ ] **Step 1: Fix TSIG key name inconsistency first**
  - `external-dns/values.yaml` line 49: `external-dns-key`
  - `external-dns-secrets/manifests/push-secret.yaml` line 32: `externaldns-key`
  - Pick ONE name, use `${TSIG_KEY_NAME}` env var for both

- [ ] **Step 2: Replace hardcodes in values.yaml**
  - `example.com` → `${DNS_ZONE}`
  - `10.1.1.20` → `${DNS_SERVER_IP}`
  - TSIG key name → `${TSIG_KEY_NAME}`

- [ ] **Step 3: Commit**

```bash
git add fleet-gitops/15-dns/
git commit -m "refactor: templatize 15-dns bundle group (fix TSIG key inconsistency)"
```

---

## Chunk 6: Bundle Group 20-monitoring

### Task 11: Templatize 20-monitoring

This is the largest bundle group. Key files:

**fleet.yaml files** (6): standard OCI/cluster pattern

**kube-prometheus-stack/values.yaml** — heavy OIDC, Grafana config:
- `grafana.example.com` → `${GRAFANA_FQDN}`
- All 4 OIDC URLs → derived from `${OIDC_ISSUER_URL}`
- `grafana-pg-rw.database.svc.cluster.local:5432` → `${GRAFANA_DB_HOST}`
- RBAC group mappings → `${RBAC_GROUP_*}` vars
- `/etc/ssl/certs/vault-root-ca.pem` — leave as-is (mount path, not env-specific)

**ingress-auth/manifests/** (30+ files):
- All gateway.yaml files — FQDNs, TLS secrets, gateway class
- All httproute.yaml files — FQDNs
- All oauth2-proxy.yaml files — OIDC issuer, redirect URLs, allowed groups, image
- `vault-root-ca.yaml` — inline PEM → `${ROOT_CA_PEM_CONTENT}`
- All SecretStore files — Vault URL

**monitoring-secrets/manifests/**:
- `vault-root-ca.yaml` — inline PEM → `${ROOT_CA_PEM_CONTENT}`
- SecretStore files — Vault URL

**alloy/manifests/daemonset.yaml** — image
**loki/manifests/statefulset.yaml** — image
**cnpg-grafana/** — image, storage class, MinIO URL

- [ ] **Step 1: fleet.yaml files** — standard pattern

- [ ] **Step 2: kube-prometheus-stack/values.yaml** — domain, OIDC, DB, RBAC groups

- [ ] **Step 3: ingress-auth gateway/httproute files** (11 pairs)
  Each gateway.yaml: FQDN → `${SERVICE_FQDN}`, TLS secret → `${SERVICE_TLS_SECRET}`, gatewayClassName → `${GATEWAY_CLASS}`
  Each httproute.yaml: FQDN → `${SERVICE_FQDN}`

  Services: vault, grafana, prometheus, alertmanager, hubble, traefik

- [ ] **Step 4: oauth2-proxy deployments** (5 files: prometheus, alertmanager, hubble, traefik, + any others)
  - `--oidc-issuer-url=` → `${OIDC_ISSUER_URL}`
  - `--redirect-url=` → derived from service FQDN
  - `--whitelist-domain=` → `.${DOMAIN}`
  - `--allowed-group=` → `${RBAC_GROUP_ADMINS}` etc.
  - `image:` → `${IMAGE_OAUTH2_PROXY}`

- [ ] **Step 5: vault-root-ca.yaml files** — inline PEM → `${ROOT_CA_PEM_INDENT4}` (or appropriate indent level)

- [ ] **Step 6: Alloy, Loki images**

- [ ] **Step 7: CNPG Grafana cluster** — image, storage class, MinIO URL

- [ ] **Step 8: Grafana dashboard configmaps with hardcoded domains**
  - `configmap-dashboard-firing-alerts.yaml` — `alertmanager.example.com` → `${ALERTMANAGER_FQDN}`
  - `configmap-dashboard-home.yaml` — various FQDNs

- [ ] **Step 9: Commit**

```bash
git add fleet-gitops/20-monitoring/
git commit -m "refactor: templatize 20-monitoring bundle group"
```

---

## Chunk 7: Bundle Group 30-harbor

### Task 12: Templatize 30-harbor

**Key files:**
- `harbor/values.yaml` — externalURL, MinIO URL, DB host, Redis sentinel, S3 region, storage class, bucket
- `harbor/manifests/gateway.yaml + httproute.yaml` — FQDN (harbor.dev.example.com)
- `harbor-manifests/manifests/harbor-oidc-config.yaml` — OIDC endpoint, admin group, image
- `harbor-manifests/manifests/gateway.yaml + httproute.yaml` — FQDN
- `minio/manifests/*.yaml` — image, Vault URL, MinIO URL, bucket names
- `cnpg-harbor/manifests/*.yaml` — image, storage class, MinIO URL
- `valkey/manifests/*.yaml` — image, Vault URL, sentinel master name

- [ ] **Step 1-8: Replace all hardcodes per file** (same patterns as above)

Harbor-specific: `harbor.dev.example.com` → `${HARBOR_FQDN}` (which defaults to `${HARBOR_HOST}`)

Add to .env.example: `HARBOR_EXTERNAL_URL=https://${HARBOR_FQDN}`

- [ ] **Step 9: Commit**

```bash
git add fleet-gitops/30-harbor/
git commit -m "refactor: templatize 30-harbor bundle group"
```

---

## Chunk 8: Bundle Group 40-gitops

### Task 13: Templatize 40-gitops

**Key files:**
- `argocd/values.yaml` — FQDN, OIDC issuer, inline PEM certs (×2), RBAC groups, storage class, images
- `argocd/manifests/gateway.yaml + httproute.yaml` — FQDN
- `argocd-manifests/manifests/secretstore.yaml` — Vault URL
- `argocd-manifests/manifests/argocd-gitlab-setup.yaml` — DOMAIN, image (embedded bash)
- `argo-rollouts/values.yaml`, `argo-rollouts/manifests/*` — FQDN, oauth2-proxy, Vault URL
- `argo-rollouts-manifests/manifests/*` — same + inline PEM
- `argo-workflows/values.yaml`, manifests — same pattern
- `argo-workflows-manifests/manifests/*` — same + inline PEM

- [ ] **Step 1: argocd/values.yaml** — This is the most complex single file
  - `domain: argo.example.com` → `domain: ${ARGOCD_FQDN}`
  - `url: https://argo.example.com` → `url: https://${ARGOCD_FQDN}`
  - OIDC issuer → `${OIDC_ISSUER_URL}`
  - **Two inline PEM blocks** → `${ROOT_CA_PEM_INDENT8}` (check exact indent level)
  - RBAC group names → `${RBAC_GROUP_*}`
  - `storageClass: harvester` → `${STORAGE_CLASS}`
  - Images (valkey, haproxy) → `${IMAGE_VALKEY}`, `${IMAGE_HAPROXY}`

- [ ] **Step 2: Gateway/HTTPRoute files** — 3 services (argocd, rollouts, workflows) × 2 file types

- [ ] **Step 3: oauth2-proxy deployments** — rollouts and workflows

- [ ] **Step 4: vault-root-ca.yaml files** — rollouts-manifests, workflows-manifests (inline PEM)

- [ ] **Step 5: argocd-gitlab-setup.yaml** — embedded bash, use env: block approach

- [ ] **Step 6: Commit**

```bash
git add fleet-gitops/40-gitops/
git commit -m "refactor: templatize 40-gitops bundle group"
```

---

## Chunk 9: Bundle Group 50-gitlab

### Task 14: Templatize 50-gitlab

**Key files:**
- `gitlab/values.yaml` — DOMAIN, DB hosts, Redis sentinel, S3 region, storage class, admin email, buckets
- `gitlab/manifests/gateway.yaml` — gitlab + kas FQDNs
- `gitlab-manifests/manifests/external-secret-oidc.yaml` — OIDC issuer, callback URL
- `gitlab-manifests/manifests/external-secret-minio-storage.yaml` — MinIO URL, S3 region
- `gitlab-manifests/manifests/secret-root-ca.yaml` — inline PEM (convert to ConfigMap!)
- `gitlab-manifests/manifests/vault-jwt-auth-setup.yaml` — DOMAIN, image (embedded bash)
- `gitlab-manifests/manifests/gitlab-admin-setup.yaml` — GITLAB_URL, admin user, image
- `runners/shared-runner-values.yaml` — GITLAB_URL, cert filename, image
- `runners/group-runner-values.yaml` — GITLAB_URL, runner tags
- `runners/security-runner-values.yaml` — GITLAB_URL
- `runners/manifests/runner-secrets-setup.yaml` — cert filename, image
- `runners/manifests/secretstore.yaml` — Vault URL
- `cnpg-gitlab/manifests/cloudnativepg-cluster.yaml` — image, storage class, MinIO URL
- `cnpg-gitlab/manifests/pgbouncer-poolers.yaml` — namespace ref
- `redis/manifests/*.yaml` — image, Vault URL, sentinel master

- [ ] **Step 1-10: Replace all hardcodes per file** (same patterns)

- [ ] **Step 11: Convert secret-root-ca.yaml from Secret to ConfigMap** (security fix)

- [ ] **Step 12: Commit**

```bash
git add fleet-gitops/50-gitlab/
git commit -m "refactor: templatize 50-gitlab bundle group"
```

---

## Chunk 10: Comments Cleanup & Verification

### Task 15: Clean up infrastructure-specific comments

- [ ] **Step 1: Search and replace comments referencing example.com**

```bash
grep -rn "aegisgroup" fleet-gitops/ --include="*.yaml" --include="*.sh" | grep "#"
```

Replace all comment references with generic descriptions or `<DOMAIN>` placeholders.

- [ ] **Step 2: Genericize RKE2/Harvester comments**

Replace environment-specific details in comments:
- "RKE2 cluster" → "target cluster"
- "rke2-prod" in comments → "<cluster>"
- "Harvester CSI" → "cluster storage class"
- Node pool descriptions (CPU/RAM specs) → remove or genericize

- [ ] **Step 3: Commit**

```bash
git add -A fleet-gitops/
git commit -m "docs: remove hardcoded infrastructure references from comments"
```

---

### Task 16: End-to-end verification

- [ ] **Step 1: Run render with current .env and check for any remaining hardcodes**

```bash
fleet-gitops/scripts/render-templates.sh
grep -rn "aegisgroup" fleet-gitops/rendered/ || echo "CLEAN"
grep -rn "192\.168\.48" fleet-gitops/rendered/ || echo "CLEAN"
grep -rn "10\.1\.1\.20" fleet-gitops/rendered/ || echo "CLEAN"
grep -rn "rke2-prod" fleet-gitops/rendered/ || echo "CLEAN"
```

All should say CLEAN.

- [ ] **Step 2: Check no env vars remain unsubstituted in rendered output**

```bash
# Look for ${VAR} patterns that weren't substituted
grep -rn '\${\w\+}' fleet-gitops/rendered/ --include="*.yaml" | grep -v '^\s*#' | head -20
```

Should return nothing (or only legitimate Helm `${VAR}` references in values.yaml).

- [ ] **Step 3: Verify embedded bash scripts are intact**

```bash
# Spot-check Job manifests
diff <(grep -c '\$' fleet-gitops/05-pki-secrets/vault-init/manifests/vault-init-job.yaml) \
     <(grep -c '\$' fleet-gitops/rendered/05-pki-secrets/vault-init/manifests/vault-init-job.yaml)
```

Counts should be similar (envsubst should not have eaten shell variables).

- [ ] **Step 4: Test push-bundles.sh in dry mode**

```bash
fleet-gitops/scripts/push-bundles.sh --help
```

- [ ] **Step 5: Commit final state**

```bash
git add -A fleet-gitops/
git commit -m "feat: complete fleet-gitops environment externalization"
```

---

## Summary of Changes

| Category | Before | After |
|----------|--------|-------|
| Domain references | 130+ hardcoded `example.com` | `${DOMAIN}` + derived FQDNs |
| OCI registry URLs | 13 fleet.yaml + 4 scripts | `${OCI_HELM_PREFIX}` / `${OCI_FLEET_PREFIX}` |
| Chart versions | Duplicated in 2 scripts + 13 fleet.yaml | Single source in `.env` |
| Cluster name | 67 `rke2-prod` references | `${FLEET_TARGET_CLUSTER}` |
| Inline PEM certs | 6 files with identical copies | Single `${ROOT_CA_PEM_FILE}` → injected at render time |
| Container images | 38 hardcoded across 35 files | `${IMAGE_*}` env vars |
| IP addresses | 3 hardcoded | `${TRAEFIK_LB_IP}`, `${DNS_SERVER_IP}` |
| Storage class | 10 `harvester` references | `${STORAGE_CLASS}` |
| RBAC groups | 8+ `platform-admins` etc. | `${RBAC_GROUP_*}` |
| OIDC URLs | 15+ full URLs | Derived from `${DOMAIN}` + `${KEYCLOAK_REALM}` |
| Comments | 20+ infrastructure-specific | Genericized |

**Total env vars in .env.example**: ~90 (most have sensible defaults)
**Files modified**: ~70 manifests + 4 scripts + 30 fleet.yaml
**New files**: 3 (env-defaults.sh, render-templates.sh, .env.example)
