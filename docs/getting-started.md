# Getting Started

This guide walks through deploying all six service bundles onto an RKE2
cluster from scratch.

## Prerequisites

### Tools

| Tool | Minimum version | Purpose |
|------|----------------|---------|
| `kubectl` | 1.28+ | Kubernetes CLI |
| `helm` | 3.14+ | Helm chart management |
| `jq` | 1.6+ | JSON processing (Vault init output) |
| `openssl` | 1.1.1+ | Root CA generation and CSR signing |
| `htpasswd` | any | Basic-auth secret generation (from `httpd-tools` or `apache2-utils`) |

Verify all tools are available:

```bash
kubectl version --client
helm version --short
jq --version
openssl version
htpasswd -V 2>&1 | head -1
```

### Cluster Access

You need a kubeconfig with cluster-admin privileges on the target RKE2 cluster:

```bash
export KUBECONFIG=/path/to/your/kubeconfig
kubectl get nodes
```

### Cluster Operators

Bundle 2 (Identity) installs the CNPG operator automatically during Phase 1.
The Redis operators must be pre-installed:

| Operator | Required by | Installation |
|----------|-------------|--------------|
| CNPG (CloudNativePG) | Keycloak, Harbor, GitLab | **Auto-installed in Bundle 2, Phase 1** |
| Redis operator (Spotahome) | Harbor (Valkey Sentinel) | Must be pre-installed |
| Redis operator (OpsTree) | GitLab (Redis Sentinel) | Must be pre-installed |

### Installing Cluster Operators

Before deploying any bundles, install the Redis operators:

**OpsTree Redis Operator** (required for GitLab Bundle 6):

```bash
# Add Helm repository
helm repo add opstree-charts https://charts.opstreelabs.in
helm repo update

# Install OpsTree Redis Operator (v0.23.0)
kubectl create ns redis-operator
helm install redis-operator opstree-charts/redis-operator \
  --namespace redis-operator \
  --version 0.23.0
```

Verify the operator is ready:

```bash
kubectl -n redis-operator get deploy redis-operator
# Should show 2 replicas ready
```

**Note:** Spotahome Redis Operator is not currently used (Harbor uses Valkey Sentinel directly via Helm chart). If you need Spotahome operator support in the future, add it with:

```bash
# Optional: Spotahome Redis Operator setup (not currently used)
# helm repo add spotahome https://charts.spotahome.com
# helm install redis-operator spotahome/redis-operator --namespace redis-operator --create-namespace
```

## Step 1: Clone the Repository

```bash
git clone https://github.com/OWNER/harvester-rke2-svcs.git
cd harvester-rke2-svcs
```

## Step 2: Generate the Root CA

The Root CA is created once and stored offline. If you already have a Root CA,
skip to Step 3.

```bash
cd services/pki

# Generate a new Root CA (default: 30-year validity, RSA 4096)
./generate-ca.sh root -o "My Organization" -d roots/
```

This creates two files:

| File | Description | Handling |
|------|-------------|----------|
| `roots/root-ca.pem` | Root CA certificate | Commit to the repo |
| `roots/root-ca-key.pem` | Root CA private key | **NEVER commit.** Store offline. |

The Root CA includes `nameConstraints` that restrict all issued certificates
to your domain, `cluster.local`, and RFC 1918 IP ranges. To customize the
permitted domain, set `NAME_CONSTRAINT_DNS` before generating:

```bash
NAME_CONSTRAINT_DNS="example.com" ./generate-ca.sh root -o "My Organization" -d roots/
```

Verify the generated certificate:

```bash
openssl x509 -in roots/root-ca.pem -noout -text | head -30
```

## Step 3: Configure Environment

```bash
cd ../../  # back to repo root
cp scripts/.env.example scripts/.env
```

Edit `scripts/.env` with values for all bundles you plan to deploy:

```bash
# Domain (required for all bundles)
DOMAIN="example.com"

# Root CA paths (required for Bundle 1, Phase 3)
ROOT_CA_CERT="${SCRIPT_DIR}/../services/pki/roots/root-ca.pem"
ROOT_CA_KEY="/path/to/offline/root-ca-key.pem"

# Keycloak passwords (required for Bundle 2)
KC_ADMIN_PASSWORD="<strong-password>"
KEYCLOAK_DB_PASSWORD="<strong-password>"
BREAKGLASS_PASSWORD="<strong-password>"

# Monitoring passwords (required for Bundle 3)
GRAFANA_ADMIN_PASSWORD="<strong-password>"
PROM_BASIC_AUTH_PASS="<strong-password>"
AM_BASIC_AUTH_PASS="<strong-password>"

# Harbor passwords (required for Bundle 4)
HARBOR_ADMIN_PASSWORD="<strong-password>"
HARBOR_DB_PASSWORD="<strong-password>"
HARBOR_REDIS_PASSWORD="<strong-password>"
HARBOR_MINIO_SECRET_KEY="<strong-password>"

# Argo GitOps passwords (required for Bundle 5)
ARGO_BASIC_AUTH_PASS="<strong-password>"
WORKFLOWS_BASIC_AUTH_PASS="<strong-password>"

# GitLab passwords (required for Bundle 6)
GITLAB_ROOT_PASSWORD="<strong-password>"
GITLAB_REDIS_PASSWORD="<strong-password>"
```

The deploy scripts derive `DOMAIN_DASHED` and `DOMAIN_DOT` automatically from
`DOMAIN`. Override them in `.env` only if you need custom values.

See `scripts/.env.example` for a complete reference of all available variables,
including Helm chart source overrides for private registries.

---

## Bundle 1: PKI & Secrets

### Step 4: Deploy Bundle 1 (PKI & Secrets)

Deploy all seven phases:

```bash
./scripts/deploy-pki-secrets.sh
```

The script is idempotent. If it fails partway through, fix the issue and
re-run. You can also resume from a specific phase:

```bash
# Resume from Phase 3 (PKI setup)
./scripts/deploy-pki-secrets.sh --from 3

# Run only Phase 2 (Vault install)
./scripts/deploy-pki-secrets.sh --phase 2
```

### What Happens During Bundle 1 Deployment

| Phase | Duration | What it does |
|-------|----------|--------------|
| 1 | ~2 min | Installs cert-manager via Helm with CRDs and Gateway API shim |
| 2 | ~3 min | Installs Vault (3-replica HA), initializes, unseals, joins Raft |
| 3 | ~1 min | Imports Root CA, generates Vault intermediate CSR, signs it with Root CA key, imports chain |
| 4 | ~30 sec | Enables Kubernetes auth in Vault, creates cert-manager role and policy, enables KV v2 |
| 5 | ~1 min | Applies cert-manager RBAC and ClusterIssuer, verifies Vault connectivity |
| 6 | ~2 min | Installs External Secrets Operator via Helm |
| 7 | ~1 min | Applies monitoring overlays, Gateway, HTTPRoute for Vault UI |

**Phase 3 is the only phase that requires the Root CA key.** After Phase 3
completes, return the key to offline storage.

### Vault Initialization Output

During Phase 2, if Vault is not yet initialized, the script creates
`vault-init.json` containing the unseal keys and root token:

```
IMPORTANT: Back up vault-init.json securely.
It contains 5 unseal keys (threshold 3) and the root token.
```

This file is gitignored. Store it in a secure location (password manager,
hardware security module, or split across trusted parties).

### Verify Bundle 1

```bash
./scripts/deploy-pki-secrets.sh --validate
```

This checks:
- Vault is initialized and unsealed
- ClusterIssuer `vault-issuer` is Ready
- ESO controller has ready replicas

**Before deploying Bundles 3 and 4:** seed the required secrets into Vault's
KV v2 engine at the paths expected by the ExternalSecret manifests. See the
`services/harbor/*/external-secret.yaml` and
`services/keycloak/*/external-secret.yaml` files for the expected KV paths.

---

## Bundle 2: Identity (Keycloak)

### Step 5: Deploy Bundle 2

Bundle 2 has two scripts: `deploy-keycloak.sh` deploys the infrastructure,
and `setup-keycloak.sh` configures Keycloak via the Admin REST API.

**Required environment variables:**

| Variable | Description |
|----------|-------------|
| `KC_ADMIN_PASSWORD` | Keycloak bootstrap admin password |
| `KEYCLOAK_DB_PASSWORD` | PostgreSQL database password for Keycloak |
| `BREAKGLASS_PASSWORD` | Password for the `admin-breakglass` user |
| `KC_REALM` | Realm name (default: `platform`) |

**Prerequisites:**
- Bundle 1 must be deployed (Vault, ESO)
- Secrets must be seeded in Vault KV v2 at the paths expected by
  `services/keycloak/*/external-secret.yaml`

#### Deploy Keycloak Infrastructure

```bash
./scripts/deploy-keycloak.sh
```

| Phase | Duration | What it does |
|-------|----------|--------------|
| 1 | ~3 min | Installs CNPG operator, deploys shared MinIO (skip if exists) |
| 2 | ~10 sec | Creates `keycloak`, `database` namespaces |
| 3 | ~30 sec | Applies ExternalSecrets for Keycloak admin, DB, and OIDC credentials |
| 4 | ~5 min | Deploys 3-instance CNPG PostgreSQL HA cluster, configures scheduled backups |
| 5 | ~3 min | Deploys Keycloak (RBAC, services, deployment), verifies health endpoint |
| 6 | ~1 min | Applies Gateway, HTTPRoute, HPA, verifies TLS certificate |
| 7 | ~30 sec | Deploys OAuth2-proxy instances for Prometheus, Alertmanager, Hubble; applies ForwardAuth middleware |
| 8 | ~30 sec | Applies monitoring dashboards, alerts, ServiceMonitors, NetworkPolicies |

#### Configure Keycloak (Post-Deploy)

After Keycloak is running and accessible at `https://keycloak.example.com`,
run the setup script to configure the realm, users, clients, and groups:

```bash
./scripts/setup-keycloak.sh
```

| Phase | What it does |
|-------|--------------|
| 1 | Creates the `platform` realm with brute-force protection |
| 2 | Creates `admin-breakglass` user with the `BREAKGLASS_PASSWORD` |
| 3 | Creates OIDC clients: `grafana`, `prometheus-oidc`, `alertmanager-oidc`, `hubble-oidc` |
| 4 | Creates `platform-admins` group, assigns breakglass user, creates groups token mapper |
| 5 | Copies browser flow to `browser-prompt-login` (forces re-authentication) |
| 6 | Prints summary of all created resources and next steps |

**After setup-keycloak.sh completes:**

1. Store OIDC client secrets in Vault at `kv/oidc/<client-id>/client-secret`
2. Re-run `deploy-keycloak.sh --phase 6` to deploy OAuth2-proxy with the
   real client secrets
3. Configure Grafana OIDC in the kube-prometheus-stack Helm values

### Verify Bundle 2

```bash
./scripts/deploy-keycloak.sh --validate
```

After deployment, Keycloak is accessible at `https://keycloak.example.com`.

---

## Bundle 3: Monitoring

### Step 6: Deploy Bundle 3

**Required environment variables:**

| Variable | Description |
|----------|-------------|
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin UI password |
| `PROM_BASIC_AUTH_PASS` | Basic-auth password for Prometheus ingress |
| `AM_BASIC_AUTH_PASS` | Basic-auth password for Alertmanager ingress |

**Prerequisites:**
- Bundle 1 must be deployed (Vault, ESO)
- Bundle 2 may be deployed (optional, for OIDC pre-configuration)

Deploy the monitoring stack:

```bash
./scripts/deploy-monitoring.sh
```

### What Happens During Bundle 3 Deployment

| Phase | Duration | What it does |
|-------|----------|--------------|
| 1 | ~2 min | Creates `monitoring` namespace, deploys Loki StatefulSet and Alloy DaemonSet |
| 2 | ~10 sec | Creates additional Prometheus scrape configs Secret |
| 3 | ~5 min | Helm installs kube-prometheus-stack (Prometheus, Grafana, Alertmanager) |
| 4 | ~30 sec | Applies PrometheusRules, ServiceMonitors, and per-service monitoring from Bundle 1 |
| 5 | ~1 min | Creates basic-auth secrets, applies Gateways/HTTPRoutes for Grafana, Prometheus, Alertmanager; deploys dashboards |
| 6 | ~2 min | Waits for Grafana, Prometheus, and TLS secrets to become ready |

### Verify Bundle 3

```bash
./scripts/deploy-monitoring.sh --validate
```

After deployment, the following UIs are accessible:

| Service | URL | Authentication |
|---------|-----|---------------|
| Grafana | `https://grafana.example.com` | Admin password (OIDC after Bundle 2) |
| Prometheus | `https://prometheus.example.com` | Basic-auth (OIDC after Bundle 2) |
| Alertmanager | `https://alertmanager.example.com` | Basic-auth (OIDC after Bundle 2) |

---

## Bundle 4: Harbor

### Step 7: Deploy Bundle 4

**Required environment variables:**

| Variable | Description |
|----------|-------------|
| `HARBOR_ADMIN_PASSWORD` | Harbor admin UI password |
| `HARBOR_DB_PASSWORD` | PostgreSQL database password for Harbor |
| `HARBOR_REDIS_PASSWORD` | Valkey/Redis password |
| `HARBOR_MINIO_SECRET_KEY` | MinIO secret key (S3 access) |

**Prerequisites:**
- Bundle 1 must be deployed (Vault, ESO)
- Bundle 2 must be deployed (Identity - Keycloak for OIDC, CNPG operator installed via Keycloak deploy)
- Secrets must be seeded in Vault KV v2 at the paths expected by
  `services/harbor/*/external-secret.yaml`
- Redis operator must be installed

Deploy Harbor:

```bash
./scripts/deploy-harbor.sh
```

### What Happens During Bundle 4 Deployment

| Phase | Duration | What it does |
|-------|----------|--------------|
| 1 | ~10 sec | Creates `harbor`, `minio`, `database` namespaces |
| 2 | ~1 min | Creates Vault K8s auth roles/policies, SecretStores, and ExternalSecrets |
| 3 | ~2 min | Deploys MinIO with PVC storage, runs bucket creation job |
| 4 | ~5 min | Deploys 3-instance CNPG PostgreSQL HA cluster, configures scheduled backups |
| 5 | ~2 min | Deploys Valkey RedisReplication + RedisSentinel |
| 6 | ~5 min | Helm installs Harbor with substituted values |
| 7 | ~1 min | Applies Gateway, HTTPRoute, HorizontalPodAutoscalers |
| 8 | ~30 sec | Applies monitoring dashboards, alerts, ServiceMonitors |

### Verify Bundle 4

```bash
./scripts/deploy-harbor.sh --validate
```

After deployment, Harbor is accessible at `https://harbor.example.com`.
Log in with the admin credentials configured in Vault.

---

## Bundle 5: GitOps (Argo)

### Step 8: Deploy Bundle 5

Bundle 5 deploys the Argo GitOps platform: ArgoCD for continuous delivery, Argo
Rollouts for progressive delivery (canary/blue-green), and Argo Workflows for
workflow automation.

**Required environment variables:**

| Variable | Description |
|----------|-------------|
| `ARGO_BASIC_AUTH_PASS` | Basic-auth password for Argo Rollouts dashboard |
| `WORKFLOWS_BASIC_AUTH_PASS` | Basic-auth password for Argo Workflows UI |

**Prerequisites:**
- Bundle 1 must be deployed (Vault, ESO)
- Bundle 2 must be deployed (Keycloak for ArgoCD OIDC SSO)
- Bundle 3 must be deployed (Monitoring - Prometheus for AnalysisTemplate queries)
- Secrets must be seeded in Vault KV v2 at the paths expected by the
  ExternalSecret manifests in `services/argo/`

Deploy the Argo platform:

```bash
./scripts/deploy-argo.sh
```

### What Happens During Bundle 5 Deployment

| Phase | Duration | What it does |
|-------|----------|--------------|
| 1 | ~10 sec | Creates `argocd`, `argo-rollouts`, `argo-workflows` namespaces |
| 2 | ~1 min | Creates Vault K8s auth roles/policies, SecretStores, ExternalSecrets per namespace |
| 3 | ~5 min | Helm installs ArgoCD (HA server with OIDC SSO configured) |
| 4 | ~3 min | Helm installs Argo Rollouts with Gateway API traffic plugin |
| 5 | ~2 min | Helm installs Argo Workflows server and controller |
| 6 | ~1 min | Applies Gateways, HTTPRoutes, basic-auth secrets, AnalysisTemplates, waits for TLS certs |
| 7 | ~30 sec | Applies monitoring dashboards, alerts, and ServiceMonitors for all three components |

### Verify Bundle 5

```bash
./scripts/deploy-argo.sh --validate
```

After deployment, the following UIs are accessible:

| Service | URL | Authentication |
|---------|-----|---------------|
| ArgoCD | `https://argo.example.com` | OIDC via Keycloak |
| Argo Rollouts | `https://rollouts.example.com` | Basic-auth |
| Argo Workflows | `https://workflows.example.com` | Basic-auth |

---

## Bundle 6: Git & CI (GitLab)

### Step 9: Deploy Bundle 6

Bundle 6 deploys GitLab EE with CNPG PostgreSQL, OpsTree Redis Sentinel,
Praefect/Gitaly for Git storage, Gateway API with SSH TCPRoute, and three
GitLab Runner types.

**Required environment variables:**

| Variable | Description |
|----------|-------------|
| `GITLAB_ROOT_PASSWORD` | GitLab root user password |
| `GITLAB_REDIS_PASSWORD` | Redis password for GitLab cache/session/queues |

**Prerequisites:**
- Bundle 1 must be deployed (Vault, ESO)
- Bundle 2 must be deployed (Keycloak for OIDC SSO, CNPG operator installed)
- Bundle 3 must be deployed (Monitoring namespace for ServiceMonitors)
- Bundle 4 must be deployed (Harbor for Runner image push credentials)
- Secrets must be seeded in Vault KV v2 at the paths expected by the
  ExternalSecret manifests in `services/gitlab/`
- OpsTree Redis operator must be installed

Deploy GitLab:

```bash
./scripts/deploy-gitlab.sh
```

### What Happens During Bundle 6 Deployment

| Phase | Duration | What it does |
|-------|----------|--------------|
| 1 | ~10 sec | Creates `gitlab`, `gitlab-runners` namespaces, ensures `database` namespace |
| 2 | ~1 min | Creates Vault K8s auth roles/policies, SecretStores, ExternalSecrets (Gitaly, Praefect, Redis, OIDC, root, Harbor push) |
| 3 | ~5 min | Deploys 3-instance CNPG PostgreSQL HA cluster, configures Praefect user/DB, scheduled backup |
| 4 | ~2 min | Deploys OpsTree RedisReplication + RedisSentinel |
| 5 | ~1 min | Applies Gateway (HTTPS + SSH), TCPRoute for SSH port 22, waits for TLS cert |
| 6 | ~30 min | Helm installs GitLab EE, waits for database migrations job, waits for core deployments (webservice, sidekiq, shell, kas) |
| 7 | ~5 min | Helm installs shared, security, and group runners in `gitlab-runners` namespace |
| 8 | ~10 sec | Applies volume autoscaler resources for dynamic PVC scaling |
| 9 | ~30 sec | Applies monitoring Kustomize, verifies HTTPS health endpoint and SSH TCPRoute |

### Post-Deploy: Upload GitLab License

After GitLab is running, upload your GitLab EE license through the Admin Area:

1. Log in at `https://gitlab.example.com` with the root password
2. Navigate to **Admin Area > Settings > General > License**
3. Upload the `.gitlab-license` file or paste the license key

### Verify Bundle 6

```bash
./scripts/deploy-gitlab.sh --validate
```

After deployment, GitLab is accessible at:

| Access Method | URL / Command | Authentication |
|---------------|---------------|---------------|
| HTTPS | `https://gitlab.example.com` | Root password or OIDC via Keycloak |
| SSH (Git) | `git clone git@gitlab.example.com:group/project.git` | SSH key |
| KAS (Agent) | `wss://kas.example.com` | Agent token |

---

## Day-2 Operations

### Unsealing Vault After Restart

Vault pods lose their unseal state on restart. To re-unseal all replicas:

```bash
./scripts/deploy-pki-secrets.sh --unseal-only
```

This reads the unseal keys from `vault-init.json` and unseals all three
replicas.

### Health Checks

Run validation across all bundles:

```bash
./scripts/deploy-pki-secrets.sh --validate
./scripts/deploy-monitoring.sh --validate
./scripts/deploy-harbor.sh --validate
./scripts/deploy-keycloak.sh --validate
./scripts/deploy-argo.sh --validate
./scripts/deploy-gitlab.sh --validate
```

### Adding Secrets for a New Application

1. Create a Vault Kubernetes auth role for the application namespace:

   ```bash
   vault write auth/kubernetes/role/eso-<namespace> \
     bound_service_account_names=<sa-name> \
     bound_service_account_namespaces=<namespace> \
     policies=<policy-name> \
     ttl=1h
   ```

2. Create a `SecretStore` in the target namespace pointing to Vault.

3. Create `ExternalSecret` resources that map Vault KV paths to Kubernetes
   Secret keys.

See `services/external-secrets/README.md` for details.

### Generating Leaf Certificates Manually

For certificates outside of cert-manager (e.g., pre-provisioned TLS for
air-gapped deployments):

```bash
cd services/pki
./generate-ca.sh leaf \
  -n my-service \
  -o "My Organization" \
  --ca-cert intermediates/vault/vault-int-ca.pem \
  --ca-key intermediates/vault/vault-int-ca-key.pem \
  --san DNS:my-service.example.com,DNS:my-service.cluster.local \
  -d /tmp/certs/
```

### Verifying Certificate Chains

```bash
cd services/pki
./generate-ca.sh verify /path/to/chain.pem
```

This displays each certificate in the chain and verifies the trust
relationship.

## Troubleshooting

### Vault pods stuck in `0/1 Running`

Vault pods start in an uninitialized and sealed state. They report `0/1` until
unsealed. During first deployment, the script handles init and unseal
automatically. For pod restarts:

```bash
./scripts/deploy-pki-secrets.sh --unseal-only
```

### ClusterIssuer shows `False` or is missing

1. Verify Vault is unsealed:
   ```bash
   kubectl exec -n vault vault-0 -- vault status
   ```

2. Verify the `vault-issuer` ServiceAccount exists:
   ```bash
   kubectl -n cert-manager get sa vault-issuer
   ```

3. Check cert-manager logs:
   ```bash
   kubectl -n cert-manager logs -l app=cert-manager --tail=50
   ```

4. Re-apply the integration phase:
   ```bash
   ./scripts/deploy-pki-secrets.sh --phase 5
   ```

### Phase 3 fails with "Root CA key path must be set"

The `ROOT_CA_KEY` variable in `scripts/.env` must point to the offline Root CA
private key. This key is only needed during Phase 3 (PKI setup). If Phase 3
has already succeeded, you can skip it:

```bash
./scripts/deploy-pki-secrets.sh --from 4
```

### ESO sync failures

1. Check ESO controller logs:
   ```bash
   kubectl -n external-secrets logs -l app.kubernetes.io/name=external-secrets --tail=50
   ```

2. Check SecretStore status in the target namespace:
   ```bash
   kubectl -n <namespace> get secretstore -o wide
   ```

3. Verify the Vault Kubernetes auth role exists for the namespace:
   ```bash
   vault read auth/kubernetes/role/eso-<namespace>
   ```

### `CHANGEME_*` tokens in applied manifests

If you see errors about unreplaced `CHANGEME_*` tokens, add the missing
token mapping to `scripts/utils/subst.sh` in the `_subst_changeme()` function.

### TLS certificate not issued for a service

1. Check the Certificate resource in the service namespace:
   ```bash
   kubectl -n <namespace> get certificate
   ```

2. Check the CertificateRequest:
   ```bash
   kubectl -n <namespace> get certificaterequest
   ```

3. Describe the Certificate for events:
   ```bash
   kubectl -n <namespace> describe certificate
   ```

The Gateway annotation `cert-manager.io/cluster-issuer: vault-issuer` tells
cert-manager to issue a certificate automatically. If the ClusterIssuer is
not Ready, the certificate will not be issued.

### CNPG PostgreSQL cluster not ready

1. Check CNPG cluster status:
   ```bash
   kubectl -n database get cluster <cluster-name> -o wide
   ```

2. Check pod logs for the primary:
   ```bash
   kubectl -n database logs -l "cnpg.io/cluster=<cluster-name>,role=primary" --tail=50
   ```

3. Verify the ExternalSecret synced the database credentials:
   ```bash
   kubectl -n database get externalsecret -o wide
   ```

### Keycloak health check fails

1. Verify Keycloak is running:
   ```bash
   kubectl -n keycloak get deployment keycloak
   ```

2. Check Keycloak logs:
   ```bash
   kubectl -n keycloak logs -l app=keycloak --tail=100
   ```

3. Verify the CNPG PostgreSQL primary is healthy:
   ```bash
   kubectl -n database get pods -l "cnpg.io/cluster=keycloak-pg,role=primary"
   ```

4. Test the health endpoint from inside the pod:
   ```bash
   kubectl exec -n keycloak deploy/keycloak -- curl -sf http://localhost:8080/health/ready
   ```

### OAuth2-proxy returns 500 or redirect loops

1. Verify the OIDC client exists in Keycloak (run `setup-keycloak.sh --phase 3`
   if missing).

2. Verify the client secret is stored in Vault and synced via ESO:
   ```bash
   kubectl -n keycloak get externalsecret -o wide
   ```

3. Check OAuth2-proxy logs:
   ```bash
   kubectl -n keycloak logs -l app=oauth2-proxy-prometheus --tail=50
   ```

4. Verify the redirect URI matches exactly what is configured in Keycloak.
