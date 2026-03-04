# Getting Started

This guide walks through deploying the PKI & Secrets bundle onto an RKE2
cluster from scratch.

## Prerequisites

### Tools

| Tool | Minimum version | Purpose |
|------|----------------|---------|
| `kubectl` | 1.28+ | Kubernetes CLI |
| `helm` | 3.14+ | Helm chart management |
| `jq` | 1.6+ | JSON processing (Vault init output) |
| `openssl` | 1.1.1+ | Root CA generation and CSR signing |

Verify all tools are available:

```bash
kubectl version --client
helm version --short
jq --version
openssl version
```

### Cluster Access

You need a kubeconfig with cluster-admin privileges on the target RKE2 cluster:

```bash
export KUBECONFIG=/path/to/your/kubeconfig
kubectl get nodes
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

Edit `scripts/.env`:

```bash
# Your domain (required)
DOMAIN="example.com"

# Path to Root CA certificate (committed to repo)
ROOT_CA_CERT="${SCRIPT_DIR}/../services/pki/roots/root-ca.pem"

# Path to Root CA private key (offline, only needed during initial PKI setup)
ROOT_CA_KEY="/path/to/offline/root-ca-key.pem"
```

The deploy script derives `DOMAIN_DASHED` and `DOMAIN_DOT` automatically from
`DOMAIN`. Override them in `.env` only if you need custom values.

## Step 4: Run the Deployment

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

### What Happens During Deployment

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

## Step 5: Verify the Deployment

Run the built-in validation check:

```bash
./scripts/deploy-pki-secrets.sh --validate
```

This checks:
- Vault is initialized and unsealed
- ClusterIssuer `vault-issuer` is Ready
- ESO controller has ready replicas

### Manual Verification

**Vault status:**

```bash
kubectl exec -n vault vault-0 -- vault status
```

Expected output shows `Initialized: true` and `Sealed: false`.

**PKI intermediate certificate:**

```bash
kubectl exec -n vault vault-0 -- env \
  VAULT_ADDR=http://127.0.0.1:8200 \
  VAULT_TOKEN="$(jq -r '.root_token' vault-init.json)" \
  vault read pki_int/ca/pem
```

**ClusterIssuer status:**

```bash
kubectl get clusterissuer vault-issuer -o wide
```

The `READY` column should show `True`.

**ESO controller:**

```bash
kubectl -n external-secrets get deployment external-secrets
```

Should show the desired number of ready replicas.

**Vault UI:**

After Phase 7, the Vault UI is accessible at `https://vault.<your-domain>`.
The TLS certificate is automatically issued by cert-manager via the Vault
intermediate CA.

## Day-2 Operations

### Unsealing Vault After Restart

Vault pods lose their unseal state on restart. To re-unseal all replicas:

```bash
./scripts/deploy-pki-secrets.sh --unseal-only
```

This reads the unseal keys from `vault-init.json` and unseals all three
replicas.

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

### TLS certificate not issued for Vault UI

1. Check the Certificate resource in the vault namespace:
   ```bash
   kubectl -n vault get certificate
   ```

2. Check the CertificateRequest:
   ```bash
   kubectl -n vault get certificaterequest
   ```

3. Describe the Certificate for events:
   ```bash
   kubectl -n vault describe certificate
   ```

The Gateway annotation `cert-manager.io/cluster-issuer: vault-issuer` tells
cert-manager to issue a certificate automatically. If the ClusterIssuer is
not Ready, the certificate will not be issued.
