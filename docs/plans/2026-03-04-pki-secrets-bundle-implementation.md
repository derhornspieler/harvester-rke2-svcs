# PKI & Secrets Bundle Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Scaffold all manifests, scripts, and monitoring for the PKI & Secrets bundle (Vault + cert-manager + ESO + PKI tooling) so the deploy script can bootstrap a fresh RKE2 cluster.

**Architecture:** Separate `services/` dirs per component, small focused shell modules under `scripts/utils/`, a single orchestrator `deploy-pki-secrets.sh` running 7 phases. Manifests use `CHANGEME_*` placeholders for domain substitution. Monitoring (ServiceMonitor + PrometheusRules + Grafana dashboard) on every service.

**Tech Stack:** Bash (ShellCheck clean), Kustomize, Helm (hashicorp/vault 0.32.0, jetstack/cert-manager v1.19.3, external-secrets v0.17.0), Vault 1.19.0, Gateway API v1, Prometheus Operator CRDs.

**Source reference:** `/home/rocky/code/rke2-cluster-via-rancher/` for manifest patterns, `/home/rocky/code/PKI/` for CA tooling.

---

## Task 1: Script Utility Modules

**Files:**
- Create: `scripts/utils/log.sh`
- Create: `scripts/utils/helm.sh`
- Create: `scripts/utils/wait.sh`
- Create: `scripts/utils/vault.sh`
- Create: `scripts/utils/subst.sh`

### Step 1: Create `scripts/utils/log.sh`

```bash
#!/usr/bin/env bash
# log.sh — Colored logging and phase timing utilities
# Source this file; do not execute directly.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

PHASE_START_TIME=""

start_phase() {
  PHASE_START_TIME=$(date +%s)
  local phase_name="$1"
  echo ""
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo -e "${BOLD}${BLUE}  ${phase_name}${NC}"
  echo -e "${BOLD}${BLUE}============================================================${NC}"
  echo ""
}

end_phase() {
  local phase_name="$1"
  local elapsed=$(( $(date +%s) - PHASE_START_TIME ))
  local mins=$(( elapsed / 60 ))
  local secs=$(( elapsed % 60 ))
  echo ""
  echo -e "${GREEN}--- ${phase_name} completed in ${mins}m ${secs}s ---${NC}"
}

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

die() {
  log_error "$@"
  exit 1
}
```

### Step 2: Create `scripts/utils/helm.sh`

```bash
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
```

### Step 3: Create `scripts/utils/wait.sh`

```bash
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
    ready=$(kubectl -n "$namespace" get pods -l "$label" --no-headers 2>/dev/null | grep -c "Running" || true)

    if [[ "$total" -gt 0 && "$total" -eq "$ready" ]]; then
      log_ok "All ${total} pod(s) with label ${label} are Running"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  log_error "Timeout waiting for pods (${label}) in ${namespace}"
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
```

### Step 4: Create `scripts/utils/vault.sh`

```bash
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
```

### Step 5: Create `scripts/utils/subst.sh`

```bash
#!/usr/bin/env bash
# subst.sh — Domain placeholder substitution for CHANGEME_* tokens
# Source this file; do not execute directly.
# Requires: log.sh sourced first, DOMAIN/DOMAIN_DASHED/DOMAIN_DOT env vars set
set -euo pipefail

_subst_changeme() {
  sed \
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
```

### Step 6: Validate all scripts with ShellCheck

Run:
```bash
shellcheck scripts/utils/log.sh scripts/utils/helm.sh scripts/utils/wait.sh scripts/utils/vault.sh scripts/utils/subst.sh
```
Expected: No warnings or errors.

### Step 7: Commit

```bash
git add scripts/utils/
git commit -m "feat: add script utility modules (log, helm, wait, vault, subst)"
```

---

## Task 2: PKI Service

**Files:**
- Create: `services/pki/.gitignore`
- Copy: `services/pki/generate-ca.sh` (from `/home/rocky/code/PKI/generate-ca.sh`)
- Copy: `services/pki/roots/aegis-group-root-ca.pem` (from `/home/rocky/code/PKI/roots/`)
- Create: `services/pki/intermediates/vault/README.md`
- Create: `services/pki/README.md`

### Step 1: Copy PKI files

```bash
mkdir -p services/pki/roots services/pki/intermediates/vault
cp /home/rocky/code/PKI/generate-ca.sh services/pki/
cp /home/rocky/code/PKI/roots/aegis-group-root-ca.pem services/pki/roots/
chmod +x services/pki/generate-ca.sh
```

### Step 2: Create `services/pki/.gitignore`

```gitignore
# Private keys NEVER committed
*-key.pem
*.key.pem
```

### Step 3: Create `services/pki/intermediates/vault/README.md`

```markdown
# Vault Intermediate CA

The Vault intermediate CA private key is generated INSIDE Vault's `pki_int` backend
and never exported to disk.

During deployment (`deploy-pki-secrets.sh` Phase 3):
1. Vault generates an intermediate CSR internally
2. The CSR is signed locally using the Root CA key
3. The signed certificate chain is imported back into Vault
4. The private key never leaves Vault's barrier encryption

To inspect the intermediate certificate:
    vault read pki_int/ca/pem
```

### Step 4: Create `services/pki/README.md`

```markdown
# PKI Service

Offline Root CA and certificate generation tooling for the Example Org PKI hierarchy.

## Hierarchy

    Offline Root CA (30yr, RSA 4096, nameConstraints)
      └── Vault Intermediate CA (pathlen:0, key inside Vault only)
            └── cert-manager vault-issuer → leaf TLS certs

## Usage

Generate a new intermediate for Vault (only needed during initial bootstrap):

    ./generate-ca.sh intermediate -n vault-int \
        --root-cert roots/aegis-group-root-ca.pem \
        --root-key roots/aegis-group-root-ca-key.pem \
        -d intermediates/vault/

Verify a certificate chain:

    ./generate-ca.sh verify intermediates/vault/ca-chain.pem

## Security

- Root CA key (`*-key.pem`) is gitignored and stored offline
- Vault intermediate key lives inside Vault only
- nameConstraints restrict all certs to: example.com, cluster.local, RFC 1918
```

### Step 5: Validate

```bash
shellcheck services/pki/generate-ca.sh
```
Expected: Clean (script is already ShellCheck-validated in source repo).

### Step 6: Commit

```bash
git add services/pki/
git commit -m "feat: add PKI service with generate-ca.sh and root CA cert"
```

---

## Task 3: Vault Service Manifests

**Files:**
- Create: `services/vault/namespace.yaml`
- Create: `services/vault/vault-values.yaml`
- Create: `services/vault/gateway.yaml`
- Create: `services/vault/httproute.yaml`
- Create: `services/vault/kustomization.yaml`

**Source reference:** `/home/rocky/code/rke2-cluster-via-rancher/services/vault/`

### Step 1: Create `services/vault/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vault
  labels:
    app: vault
```

### Step 2: Create `services/vault/vault-values.yaml`

Adapt from source (`/home/rocky/code/rke2-cluster-via-rancher/services/vault/vault-values.yaml`). Key settings:
- 3 replicas, HA Raft storage
- `tls_disable = 1` (TLS at Traefik, not Vault)
- `unauthenticated_metrics_access = true` for Prometheus
- Resources: 250m/256Mi requests, 1/512Mi limits
- Node selector: `workload-type: database`
- Anti-affinity across nodes
- StorageClass: `harvester`, 10Gi per replica

Copy the file verbatim from source:
```bash
cp /home/rocky/code/rke2-cluster-via-rancher/services/vault/vault-values.yaml services/vault/
```

### Step 3: Create `services/vault/gateway.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: vault
  namespace: vault
  annotations:
    cert-manager.io/cluster-issuer: vault-issuer
spec:
  gatewayClassName: traefik
  listeners:
    - name: https
      protocol: HTTPS
      port: 8443
      hostname: vault.CHANGEME_DOMAIN
      tls:
        mode: Terminate
        certificateRefs:
          - name: vault-CHANGEME_DOMAIN_DASHED-tls
      allowedRoutes:
        namespaces:
          from: Same
```

### Step 4: Create `services/vault/httproute.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: vault
  namespace: vault
spec:
  parentRefs:
    - name: vault
      namespace: vault
      sectionName: https
  hostnames:
    - "vault.CHANGEME_DOMAIN"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: vault
          port: 8200
```

### Step 5: Create `services/vault/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - gateway.yaml
  - httproute.yaml
  - monitoring/
```

### Step 6: Validate Kustomize build

```bash
kustomize build services/vault/
```
Expected: Renders namespace, gateway, httproute YAML (monitoring/ will fail until Task 4).

Note: Run this after Task 4 (Vault monitoring) is complete.

### Step 7: Commit

```bash
git add services/vault/
git commit -m "feat: add Vault service manifests (namespace, helm values, gateway, httproute)"
```

---

## Task 4: Vault Monitoring

**Files:**
- Create: `services/vault/monitoring/kustomization.yaml`
- Create: `services/vault/monitoring/service-monitor.yaml`
- Create: `services/vault/monitoring/vault-alerts.yaml`
- Create: `services/vault/monitoring/configmap-dashboard-vault.yaml`

**Source reference:** `/home/rocky/code/rke2-cluster-via-rancher/services/vault/monitoring/`

### Step 1: Create `services/vault/monitoring/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - service-monitor.yaml
  - vault-alerts.yaml
  - configmap-dashboard-vault.yaml
```

### Step 2: Copy monitoring files from source

```bash
mkdir -p services/vault/monitoring
cp /home/rocky/code/rke2-cluster-via-rancher/services/vault/monitoring/service-monitor.yaml \
   services/vault/monitoring/
cp /home/rocky/code/rke2-cluster-via-rancher/services/vault/monitoring/vault-alerts.yaml \
   services/vault/monitoring/
cp /home/rocky/code/rke2-cluster-via-rancher/services/vault/monitoring/configmap-dashboard-vault.yaml \
   services/vault/monitoring/
```

### Step 3: Validate full Kustomize build

```bash
kustomize build services/vault/
```
Expected: Renders all Vault resources without errors.

### Step 4: Commit

```bash
git add services/vault/monitoring/
git commit -m "feat: add Vault monitoring (ServiceMonitor, alerts, Grafana dashboard)"
```

---

## Task 5: cert-manager Service Manifests

**Files:**
- Create: `services/cert-manager/namespace.yaml`
- Create: `services/cert-manager/rbac.yaml`
- Create: `services/cert-manager/cluster-issuer.yaml`
- Create: `services/cert-manager/kustomization.yaml`

**Source reference:** `/home/rocky/code/rke2-cluster-via-rancher/services/cert-manager/`

### Step 1: Create `services/cert-manager/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager
  labels:
    app: cert-manager
```

### Step 2: Create `services/cert-manager/rbac.yaml`

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-issuer
  namespace: cert-manager
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: vault-issuer-token-creator
  namespace: cert-manager
rules:
  - apiGroups: [""]
    resources: ["serviceaccounts/token"]
    resourceNames: ["vault-issuer"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: vault-issuer-token-creator-binding
  namespace: cert-manager
subjects:
  - kind: ServiceAccount
    name: cert-manager
    namespace: cert-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: vault-issuer-token-creator
```

### Step 3: Create `services/cert-manager/cluster-issuer.yaml`

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-issuer
spec:
  vault:
    path: pki_int/sign/CHANGEME_DOMAIN_DOT
    server: CHANGEME_VAULT_ADDR
    auth:
      kubernetes:
        role: cert-manager-issuer
        mountPath: /v1/auth/kubernetes
        serviceAccountRef:
          name: vault-issuer
```

### Step 4: Create `services/cert-manager/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - rbac.yaml
  - cluster-issuer.yaml
  - monitoring/
```

### Step 5: Commit

```bash
git add services/cert-manager/
git commit -m "feat: add cert-manager service manifests (namespace, RBAC, ClusterIssuer)"
```

---

## Task 6: cert-manager Monitoring

**Files:**
- Create: `services/cert-manager/monitoring/kustomization.yaml`
- Copy: `services/cert-manager/monitoring/service-monitor.yaml`
- Copy: `services/cert-manager/monitoring/certmanager-alerts.yaml`
- Copy: `services/cert-manager/monitoring/configmap-dashboard-cert-manager.yaml`

### Step 1: Copy from source and create kustomization

```bash
mkdir -p services/cert-manager/monitoring
cp /home/rocky/code/rke2-cluster-via-rancher/services/cert-manager/monitoring/service-monitor.yaml \
   services/cert-manager/monitoring/
cp /home/rocky/code/rke2-cluster-via-rancher/services/cert-manager/monitoring/certmanager-alerts.yaml \
   services/cert-manager/monitoring/
cp /home/rocky/code/rke2-cluster-via-rancher/services/cert-manager/monitoring/configmap-dashboard-cert-manager.yaml \
   services/cert-manager/monitoring/
```

### Step 2: Create `services/cert-manager/monitoring/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - service-monitor.yaml
  - certmanager-alerts.yaml
  - configmap-dashboard-cert-manager.yaml
```

### Step 3: Validate

```bash
kustomize build services/cert-manager/
```
Expected: Renders all cert-manager resources.

### Step 4: Commit

```bash
git add services/cert-manager/monitoring/
git commit -m "feat: add cert-manager monitoring (ServiceMonitor, alerts, Grafana dashboard)"
```

---

## Task 7: External Secrets Service Manifests

**Files:**
- Create: `services/external-secrets/namespace.yaml`
- Create: `services/external-secrets/kustomization.yaml`

**Source reference:** `/home/rocky/code/rke2-cluster-via-rancher/services/external-secrets/`

### Step 1: Create `services/external-secrets/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: external-secrets
```

### Step 2: Create `services/external-secrets/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - monitoring/
```

### Step 3: Commit

```bash
git add services/external-secrets/
git commit -m "feat: add external-secrets service manifests (namespace)"
```

---

## Task 8: External Secrets Monitoring

**Files:**
- Copy: `services/external-secrets/monitoring/servicemonitor.yaml`
- Copy: `services/external-secrets/monitoring/external-secrets-alerts.yaml`
- Copy: `services/external-secrets/monitoring/configmap-dashboard-external-secrets.yaml`
- Create: `services/external-secrets/monitoring/kustomization.yaml`

### Step 1: Copy from source and create kustomization

```bash
mkdir -p services/external-secrets/monitoring
cp /home/rocky/code/rke2-cluster-via-rancher/services/external-secrets/monitoring/servicemonitor.yaml \
   services/external-secrets/monitoring/
cp /home/rocky/code/rke2-cluster-via-rancher/services/external-secrets/monitoring/external-secrets-alerts.yaml \
   services/external-secrets/monitoring/
cp /home/rocky/code/rke2-cluster-via-rancher/services/external-secrets/monitoring/configmap-dashboard-external-secrets.yaml \
   services/external-secrets/monitoring/
```

### Step 2: Create `services/external-secrets/monitoring/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - servicemonitor.yaml
  - external-secrets-alerts.yaml
  - configmap-dashboard-external-secrets.yaml
```

### Step 3: Validate

```bash
kustomize build services/external-secrets/
```
Expected: Renders all ESO resources.

### Step 4: Commit

```bash
git add services/external-secrets/monitoring/
git commit -m "feat: add external-secrets monitoring (ServiceMonitor, alerts, Grafana dashboard)"
```

---

## Task 9: Environment Configuration

**Files:**
- Create: `scripts/.env.example`

### Step 1: Create `scripts/.env.example`

```bash
# deploy-pki-secrets.sh environment configuration
# Copy to .env and fill in values before running.

# Domain configuration (required)
DOMAIN="example.com"
# Auto-derived (override if needed):
# DOMAIN_DASHED="aegisgroup-ch"
# DOMAIN_DOT="aegisgroup-dot-ch"

# Vault init output file (created during Phase 2)
VAULT_INIT_FILE="${SCRIPT_DIR}/../vault-init.json"

# Root CA paths (required for Phase 3: PKI setup)
ROOT_CA_CERT="${SCRIPT_DIR}/../services/pki/roots/aegis-group-root-ca.pem"
ROOT_CA_KEY=""  # Path to offline Root CA key — NOT committed to git

# Kubeconfig (optional — uses current context if not set)
# KUBECONFIG="/path/to/kubeconfig"
```

### Step 2: Commit

```bash
git add scripts/.env.example
git commit -m "feat: add .env.example for deploy script configuration"
```

---

## Task 10: Deploy Script (deploy-pki-secrets.sh)

**Files:**
- Create: `scripts/deploy-pki-secrets.sh`

This is the largest single file. It implements 7 phases plus CLI argument parsing.

### Step 1: Create `scripts/deploy-pki-secrets.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source utility modules
source "${SCRIPT_DIR}/utils/log.sh"
source "${SCRIPT_DIR}/utils/helm.sh"
source "${SCRIPT_DIR}/utils/wait.sh"
source "${SCRIPT_DIR}/utils/vault.sh"
source "${SCRIPT_DIR}/utils/subst.sh"

# Load environment
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
fi

# Domain defaults
DOMAIN="${DOMAIN:?DOMAIN must be set}"
DOMAIN_DASHED="${DOMAIN_DASHED:-$(echo "$DOMAIN" | tr '.' '-')}"
DOMAIN_DOT="${DOMAIN_DOT:-$(echo "$DOMAIN" | sed 's/\./-dot-/g')}"
export DOMAIN DOMAIN_DASHED DOMAIN_DOT

# Vault init file
VAULT_INIT_FILE="${VAULT_INIT_FILE:-${REPO_ROOT}/vault-init.json}"

# Root CA paths
ROOT_CA_CERT="${ROOT_CA_CERT:-${REPO_ROOT}/services/pki/roots/aegis-group-root-ca.pem}"
ROOT_CA_KEY="${ROOT_CA_KEY:-}"

# ---------------------------------------------------------------------------
# CLI Parsing
# ---------------------------------------------------------------------------
PHASE_FROM=1
PHASE_TO=7
SINGLE_PHASE=""
UNSEAL_ONLY=false
VALIDATE_ONLY=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Deploy PKI & Secrets bundle (Vault + cert-manager + ESO).

Options:
  --phase N       Run only phase N
  --from N        Start from phase N (default: 1)
  --to N          Stop after phase N (default: 7)
  --unseal-only   Just unseal Vault (skip everything else)
  --validate      Health check all components (no changes)
  -h, --help      Show this help

Phases:
  1  cert-manager    Helm install (CRDs, gateway-shim)
  2  Vault           Helm install -> init -> unseal -> Raft join
  3  PKI             Import Root CA -> intermediate CSR -> sign -> import chain
  4  Vault K8s Auth  Enable K8s auth, create roles
  5  cert-manager    Apply RBAC, ClusterIssuer, verify TLS
  6  ESO             Helm install, verify controller
  7  Kustomize       Apply monitoring, gateways, httproutes
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)     SINGLE_PHASE="$2"; PHASE_FROM="$2"; PHASE_TO="$2"; shift 2 ;;
    --from)      PHASE_FROM="$2"; shift 2 ;;
    --to)        PHASE_TO="$2"; shift 2 ;;
    --unseal-only) UNSEAL_ONLY=true; shift ;;
    --validate)  VALIDATE_ONLY=true; shift ;;
    -h|--help)   usage ;;
    *)           die "Unknown option: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation mode
# ---------------------------------------------------------------------------
if [[ "$VALIDATE_ONLY" == "true" ]]; then
  start_phase "Validation: Health Check"
  log_info "Checking Vault..."
  kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null | jq '{initialized, sealed, cluster_name}' || log_error "Vault unreachable"
  log_info "Checking cert-manager..."
  kubectl get clusterissuer vault-issuer -o jsonpath='{.status.conditions[0].status}' 2>/dev/null && echo "" || log_error "ClusterIssuer not found"
  log_info "Checking ESO..."
  kubectl -n external-secrets get deployment external-secrets -o jsonpath='{.status.readyReplicas}' 2>/dev/null && echo " replica(s) ready" || log_error "ESO not found"
  end_phase "Validation: Health Check"
  exit 0
fi

# ---------------------------------------------------------------------------
# Unseal-only mode
# ---------------------------------------------------------------------------
if [[ "$UNSEAL_ONLY" == "true" ]]; then
  start_phase "Unseal Vault"
  [[ -f "$VAULT_INIT_FILE" ]] || die "Vault init file not found: ${VAULT_INIT_FILE}"
  vault_unseal_all "$VAULT_INIT_FILE"
  end_phase "Unseal Vault"
  exit 0
fi

# ---------------------------------------------------------------------------
# Phase 1: cert-manager
# ---------------------------------------------------------------------------
if [[ $PHASE_FROM -le 1 && $PHASE_TO -ge 1 ]]; then
  start_phase "Phase 1: cert-manager"

  helm_repo_add jetstack https://charts.jetstack.io

  helm_install_if_needed cert-manager jetstack/cert-manager cert-manager \
    --version v1.19.3 \
    --set crds.enabled=true \
    --set config.apiVersion=controller.config.cert-manager.io/v1alpha1 \
    --set config.kind=ControllerConfiguration \
    --set config.enableGatewayAPI=true \
    --set nodeSelector.workload-type=general \
    --wait --timeout 5m

  wait_for_deployment cert-manager cert-manager 300s

  end_phase "Phase 1: cert-manager"
fi

# ---------------------------------------------------------------------------
# Phase 2: Vault
# ---------------------------------------------------------------------------
if [[ $PHASE_FROM -le 2 && $PHASE_TO -ge 2 ]]; then
  start_phase "Phase 2: Vault"

  helm_repo_add hashicorp https://helm.releases.hashicorp.com

  helm_install_if_needed vault hashicorp/vault vault \
    -f "${REPO_ROOT}/services/vault/vault-values.yaml" \
    --wait --timeout 5m

  wait_for_pods_ready vault "app.kubernetes.io/name=vault" 300

  # Init (only if not already initialized)
  if ! vault_is_initialized; then
    vault_init "$VAULT_INIT_FILE"
    log_warn "IMPORTANT: Back up ${VAULT_INIT_FILE} securely. It contains unseal keys and root token."
  else
    log_info "Vault already initialized"
  fi

  # Unseal (only if sealed)
  if vault_is_sealed; then
    [[ -f "$VAULT_INIT_FILE" ]] || die "Vault is sealed but init file not found: ${VAULT_INIT_FILE}"
    vault_unseal_all "$VAULT_INIT_FILE"
  else
    log_info "Vault already unsealed"
  fi

  # Join replicas to Raft cluster
  local root_token
  root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")
  for i in 1 2; do
    local joined
    joined=$(kubectl exec -n vault "vault-${i}" -- vault status -format=json 2>/dev/null | jq -r '.storage_type' || echo "")
    if [[ "$joined" != "raft" ]]; then
      log_info "Joining vault-${i} to Raft cluster..."
      kubectl exec -n vault "vault-${i}" -- vault operator raft join http://vault-0.vault-internal:8200
      vault_unseal_replica "$i" "$VAULT_INIT_FILE"
    fi
  done

  end_phase "Phase 2: Vault"
fi

# ---------------------------------------------------------------------------
# Phase 3: PKI
# ---------------------------------------------------------------------------
if [[ $PHASE_FROM -le 3 && $PHASE_TO -ge 3 ]]; then
  start_phase "Phase 3: PKI Setup"

  [[ -f "$ROOT_CA_CERT" ]] || die "Root CA cert not found: ${ROOT_CA_CERT}"
  [[ -n "$ROOT_CA_KEY" && -f "$ROOT_CA_KEY" ]] || die "Root CA key path must be set (ROOT_CA_KEY)"

  local root_token
  root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")

  # Enable PKI secrets engine for Root CA
  vault_exec "$root_token" secrets enable -path=pki pki 2>/dev/null || log_info "pki engine already enabled"
  vault_exec "$root_token" secrets tune -max-lease-ttl=87600h pki

  # Import Root CA certificate (public cert only — key stays offline)
  log_info "Importing Root CA certificate into Vault pki/"
  kubectl cp "$ROOT_CA_CERT" vault/vault-0:/tmp/root-ca.pem
  vault_exec "$root_token" write pki/config/ca pem_bundle=@/tmp/root-ca.pem

  # Enable intermediate PKI
  vault_exec "$root_token" secrets enable -path=pki_int pki 2>/dev/null || log_info "pki_int engine already enabled"
  vault_exec "$root_token" secrets tune -max-lease-ttl=43800h pki_int

  # Generate intermediate CSR inside Vault
  log_info "Generating intermediate CSR inside Vault..."
  vault_exec "$root_token" write -format=json \
    pki_int/intermediate/generate/internal \
    common_name="Example Org Vault Intermediate CA" \
    organization="Example Org" \
    key_type=rsa \
    key_bits=4096 \
    | jq -r '.data.csr' > /tmp/vault-intermediate.csr

  # Sign the intermediate CSR with the offline Root CA key
  log_info "Signing intermediate CSR with Root CA..."
  openssl x509 -req -days 5475 \
    -in /tmp/vault-intermediate.csr \
    -CA "$ROOT_CA_CERT" \
    -CAkey "$ROOT_CA_KEY" \
    -CAcreateserial \
    -extfile <(printf "basicConstraints=critical,CA:true,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign") \
    -out /tmp/vault-intermediate.pem

  # Create certificate chain (intermediate + root)
  cat /tmp/vault-intermediate.pem "$ROOT_CA_CERT" > /tmp/vault-intermediate-chain.pem

  # Import signed chain into Vault
  log_info "Importing signed intermediate chain into Vault..."
  kubectl cp /tmp/vault-intermediate-chain.pem vault/vault-0:/tmp/intermediate-chain.pem
  vault_exec "$root_token" write pki_int/intermediate/set-signed \
    certificate=@/tmp/intermediate-chain.pem

  # Configure signing role
  vault_exec "$root_token" write "pki_int/roles/${DOMAIN_DOT}" \
    allowed_domains="${DOMAIN}" \
    allowed_domains="cluster.local" \
    allow_subdomains=true \
    max_ttl=720h \
    generate_lease=true

  # Clean up temp files
  rm -f /tmp/vault-intermediate.csr /tmp/vault-intermediate.pem /tmp/vault-intermediate-chain.pem

  log_ok "PKI hierarchy established: Root CA -> Vault Intermediate (pathlen:0)"

  end_phase "Phase 3: PKI Setup"
fi

# ---------------------------------------------------------------------------
# Phase 4: Vault Kubernetes Auth
# ---------------------------------------------------------------------------
if [[ $PHASE_FROM -le 4 && $PHASE_TO -ge 4 ]]; then
  start_phase "Phase 4: Vault Kubernetes Auth"

  local root_token
  root_token=$(jq -r '.root_token' "$VAULT_INIT_FILE")

  # Enable Kubernetes auth
  vault_exec "$root_token" auth enable kubernetes 2>/dev/null || log_info "kubernetes auth already enabled"

  # Configure K8s auth with in-cluster values
  vault_exec "$root_token" write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc:443"

  # cert-manager issuer role
  vault_exec "$root_token" write auth/kubernetes/role/cert-manager-issuer \
    bound_service_account_names=vault-issuer \
    bound_service_account_namespaces=cert-manager \
    policies=cert-manager-pki \
    ttl=1h

  # cert-manager PKI policy
  vault_exec "$root_token" policy write cert-manager-pki - <<POLICY
path "pki_int/sign/${DOMAIN_DOT}" {
  capabilities = ["create", "update"]
}
path "pki_int/issue/${DOMAIN_DOT}" {
  capabilities = ["create"]
}
POLICY

  # Enable KV v2 for application secrets
  vault_exec "$root_token" secrets enable -version=2 -path=kv kv 2>/dev/null || log_info "kv engine already enabled"

  log_ok "Vault K8s auth configured with cert-manager and KV roles"

  end_phase "Phase 4: Vault Kubernetes Auth"
fi

# ---------------------------------------------------------------------------
# Phase 5: cert-manager Integration
# ---------------------------------------------------------------------------
if [[ $PHASE_FROM -le 5 && $PHASE_TO -ge 5 ]]; then
  start_phase "Phase 5: cert-manager Integration"

  # Apply RBAC (ServiceAccount, Role, RoleBinding for vault-issuer)
  kubectl apply -f "${REPO_ROOT}/services/cert-manager/rbac.yaml"

  # Apply ClusterIssuer (needs domain substitution)
  kube_apply_subst "${REPO_ROOT}/services/cert-manager/cluster-issuer.yaml"

  # Wait for ClusterIssuer to become Ready
  wait_for_clusterissuer vault-issuer 300

  end_phase "Phase 5: cert-manager Integration"
fi

# ---------------------------------------------------------------------------
# Phase 6: External Secrets Operator
# ---------------------------------------------------------------------------
if [[ $PHASE_FROM -le 6 && $PHASE_TO -ge 6 ]]; then
  start_phase "Phase 6: External Secrets Operator"

  helm_repo_add external-secrets https://charts.external-secrets.io

  helm_install_if_needed external-secrets external-secrets/external-secrets external-secrets \
    --set installCRDs=true \
    --set serviceMonitor.enabled=true \
    --set resources.requests.cpu=100m \
    --set resources.requests.memory=128Mi \
    --set resources.limits.cpu=500m \
    --set resources.limits.memory=512Mi \
    --set nodeSelector.workload-type=general \
    --wait --timeout 5m

  wait_for_deployment external-secrets external-secrets 300s

  log_ok "ESO controller is running"

  end_phase "Phase 6: External Secrets Operator"
fi

# ---------------------------------------------------------------------------
# Phase 7: Kustomize Overlays (monitoring, gateways)
# ---------------------------------------------------------------------------
if [[ $PHASE_FROM -le 7 && $PHASE_TO -ge 7 ]]; then
  start_phase "Phase 7: Kustomize Overlays"

  # Apply Vault gateway and httproute (needs domain substitution)
  kube_apply_subst "${REPO_ROOT}/services/vault/gateway.yaml"
  kube_apply_subst "${REPO_ROOT}/services/vault/httproute.yaml"

  # Apply monitoring (no substitution needed — uses label selectors)
  kubectl apply -k "${REPO_ROOT}/services/vault/monitoring/"
  kubectl apply -k "${REPO_ROOT}/services/cert-manager/monitoring/"
  kubectl apply -k "${REPO_ROOT}/services/external-secrets/monitoring/"

  # Wait for Vault TLS certificate (issued by gateway-shim)
  wait_for_tls_secret vault "vault-${DOMAIN_DASHED}-tls" 300

  log_ok "All Kustomize overlays applied"

  end_phase "Phase 7: Kustomize Overlays"
fi

log_ok "PKI & Secrets bundle deployment complete"
```

### Step 2: Make executable

```bash
chmod +x scripts/deploy-pki-secrets.sh
```

### Step 3: Validate with ShellCheck

```bash
shellcheck scripts/deploy-pki-secrets.sh
```
Expected: Clean. Fix any issues found.

Note: `local` inside conditional blocks is a known ShellCheck pattern (SC2155). If flagged, split declaration and assignment.

### Step 4: Commit

```bash
git add scripts/deploy-pki-secrets.sh
git commit -m "feat: add deploy-pki-secrets.sh orchestrator (7 phases)"
```

---

## Task 11: Service READMEs

**Files:**
- Create: `services/vault/README.md`
- Create: `services/cert-manager/README.md`
- Create: `services/external-secrets/README.md`
- Create: `README.md` (project root)

### Step 1: Create `services/vault/README.md`

```markdown
# Vault

HashiCorp Vault for secrets management and PKI.

## Architecture

- 3-replica HA cluster with integrated Raft storage
- Shamir unsealing (5 shares, threshold 3)
- TLS terminated at Traefik Gateway (Vault listens on HTTP internally)
- PKI intermediate CA for cert-manager leaf certificate signing

## Deployment

Deployed by `scripts/deploy-pki-secrets.sh` phases 2-4.

## Monitoring

- ServiceMonitor: `/v1/sys/metrics?format=prometheus` (30s interval)
- Alerts: VaultSealed (2m), VaultDown (2m), VaultLeaderLost (10m)
- Grafana dashboard: seal status, Raft health, barrier ops, commit time

## Unsealing

After pod restart:

    ./scripts/deploy-pki-secrets.sh --unseal-only
```

### Step 2: Create `services/cert-manager/README.md`

```markdown
# cert-manager

Automated TLS certificate management via Vault PKI.

## Architecture

- ClusterIssuer `vault-issuer` calls Vault `pki_int/sign/<role>` endpoint
- Gateway API shim auto-creates Certificate resources from Gateway annotations
- cert-manager does NOT hold any CA key — it is a requestor only

## Deployment

Deployed by `scripts/deploy-pki-secrets.sh` phases 1 and 5.

## Monitoring

- Alerts: CertExpiringSoon (<7d), CertNotReady (15m), CertManagerDown (5m)
- Grafana dashboard: certificate expiry timeline, readiness, controller sync rate
```

### Step 3: Create `services/external-secrets/README.md`

```markdown
# External Secrets Operator

Syncs secrets from Vault KV v2 to Kubernetes Secrets.

## Architecture

- Per-namespace SecretStore resources (not ClusterSecretStore)
- Each namespace gets a Vault K8s auth role `eso-<namespace>`
- Refresh interval: 15 minutes

## Deployment

Deployed by `scripts/deploy-pki-secrets.sh` phase 6.

## Adding Secrets for a New Service

1. Create a Vault K8s auth role for the namespace
2. Create a SecretStore in the namespace
3. Create ExternalSecret resources mapping Vault paths to K8s Secret keys

See `services/service-template/` (future) for a complete example.

## Monitoring

- Alerts: ESODown (5m), SyncFailure (10m), ReconcileErrors (15m)
- Grafana dashboard: sync status, reconcile rate, error tracking
```

### Step 4: Create `README.md` (project root)

```markdown
# harvester-rke2-svcs

Service deployments for RKE2 clusters.

## Quick Start

    cp scripts/.env.example scripts/.env
    # Edit scripts/.env with your domain and Root CA key path
    ./scripts/deploy-pki-secrets.sh

## Service Bundles

| Bundle | Services | Status |
|--------|----------|--------|
| PKI & Secrets | Vault, cert-manager, ESO, PKI tooling | Active |

## Structure

    services/           # One directory per service (Kustomize + Helm values)
    scripts/            # Deploy scripts and utility modules
    scripts/utils/      # Small focused shell modules (log, helm, wait, vault, subst)
    docs/plans/         # Design documents and implementation plans
    memory/             # Project memory for Claude Code agents

## Requirements

- RKE2 cluster with kubeconfig access
- kubectl, helm, jq, openssl
- Root CA key (offline, for initial PKI setup only)
```

### Step 5: Commit

```bash
git add services/vault/README.md services/cert-manager/README.md services/external-secrets/README.md README.md
git commit -m "docs: add READMEs for all services and project root"
```

---

## Task 12: Validation Pass

### Step 1: ShellCheck all scripts

```bash
shellcheck scripts/deploy-pki-secrets.sh scripts/utils/*.sh services/pki/generate-ca.sh
```
Expected: Clean. Fix any issues.

### Step 2: Kustomize build all services

```bash
kustomize build services/vault/
kustomize build services/cert-manager/
kustomize build services/external-secrets/
```
Expected: All render without errors.

### Step 3: yamllint all YAML

```bash
find services/ -name '*.yaml' -exec yamllint -d relaxed {} +
```
Expected: Clean or minor warnings only (line length).

### Step 4: Fix any issues found, commit

```bash
git add -A
git commit -m "fix: resolve validation issues from shellcheck/yamllint/kustomize"
```
Only create this commit if there were actual fixes needed.

---

## Task 13: Final Commit and Summary

### Step 1: Verify complete file tree

```bash
find . -not -path './.git/*' -not -path './memory/*' -not -path './.claude/*' | sort
```
Expected: Matches the design document layout.

### Step 2: Git log review

```bash
git log --oneline
```
Expected: Clean commit history with one commit per task.
