# IdentityWebUI — Setup Checklist

Step-by-step guide for deploying the Identity Portal CI/CD pipeline.

## Prerequisites

- GitLab instance at `gitlab.aegisgroup.ch`
- Harbor registry at `harbor.dev.aegisgroup.ch`
- ArgoCD deployed with access to target cluster
- Keycloak with `platform` realm configured
- Vault with ESO integration

## 1. GitLab Setup

1. Create the `IDP` group in GitLab
2. Create the `IdentityWebUI` project under the `IDP` group
3. Set **group-level** CI/CD variables (Settings → CI/CD → Variables):

| Variable | Value | Protected | Masked |
|----------|-------|-----------|--------|
| `DOMAIN` | `aegisgroup.ch` | Yes | No |
| `HARBOR_CI_USER` | Harbor robot account username | Yes | No |
| `HARBOR_CI_PASSWORD` | Harbor robot account password | Yes | Yes |
| `ARGOCD_PASSWORD` | ArgoCD CI bot password | Yes | Yes |

## 2. Harbor Setup

1. Log into Harbor at `https://harbor.dev.aegisgroup.ch`
2. Create a new project named `idp`
3. Create a robot account with push/pull access to the `idp` project
4. Use the robot account credentials for `HARBOR_CI_USER` / `HARBOR_CI_PASSWORD`

## 3. Push Application Code

```bash
# Clone the source
cp -r /path/to/operators/identity-portal/* /tmp/identity-webui/

# Initialize git repo
cd /tmp/identity-webui
git init
git remote add origin git@gitlab.aegisgroup.ch:IDP/IdentityWebUI.git

# Copy CI/CD and K8s manifests
cp /path/to/gitlab-ci/.gitlab-ci.yml .
cp -r /path/to/gitlab-ci/k8s .
cp -r /path/to/gitlab-ci/argocd .

# Push main branch
git add .
git commit -m "feat: initial Identity Portal with CI/CD pipeline"
git push -u origin main

# Create deploy branch
git checkout -b deploy
git push -u origin deploy
git checkout main
```

## 4. Keycloak OIDC Client

Create the `identity-portal` OIDC client in the `platform` realm:

- **Client ID**: `identity-portal`
- **Client Protocol**: openid-connect
- **Access Type**: confidential
- **Valid Redirect URIs**: `https://identity.aegisgroup.ch/*`
- **Web Origins**: `https://identity.aegisgroup.ch`
- **Post Logout Redirect URIs**: `https://identity.aegisgroup.ch/*`
- **Code Challenge Method**: S256 (PKCE)

The OIDC client secret is **auto-generated** by ESO's Password generator and
pushed to Vault via PushSecret (`updatePolicy: IfNotExists`). You do NOT need
to manually seed it. However, Keycloak needs the same secret configured — see
step 6.

## 5. Vault ESO Integration

The K8s manifests include a `secretstore.yaml` that creates both `vault-backend`
(reader) and `vault-writer` (writer) SecretStores. For these to work, create two
Vault roles:

1. Create Vault policy `eso-identity-portal` allowing **read** access to
   `kv/data/services/identity-portal/*`
2. Create Vault policy `eso-writer-identity-portal` allowing **read + create +
   update** access to `kv/data/services/identity-portal/*`
3. Create Kubernetes auth roles in Vault:

```bash
# Reader role (for ExternalSecret pulls)
vault write auth/kubernetes/role/eso-identity-portal \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=identity-portal \
  policies=eso-identity-portal \
  ttl=1h

# Writer role (for PushSecret pushes)
vault write auth/kubernetes/role/eso-writer-identity-portal \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=identity-portal \
  policies=eso-writer-identity-portal \
  ttl=1h
```

## 6. Keycloak OIDC Client Secret Sync

Once the application deploys, ESO will:
1. Generate a random 32-char password
2. Push it to Vault at `kv/services/identity-portal/oidc-secret`
3. Pull it back into K8s Secret `identity-portal-secret`

You need to retrieve the generated secret and configure it in Keycloak:

```bash
# After first deploy, read the generated secret from Vault
vault kv get -field=KEYCLOAK_CLIENT_SECRET kv/services/identity-portal/oidc-secret

# Set this as the client secret in Keycloak admin console:
# Clients → identity-portal → Credentials → Regenerate Secret (paste the value)
```

Alternatively, if you want Keycloak to generate the secret (and you seed Vault
manually), delete the `push-secret.yaml` from kustomization and use:

```bash
vault kv put kv/services/identity-portal/oidc-secret \
  KEYCLOAK_CLIENT_SECRET="<secret-from-keycloak>"
```

## 7. ArgoCD Application

Apply the ArgoCD Application CRD (substitute `CHANGEME_DOMAIN`):

```bash
sed 's/CHANGEME_DOMAIN/aegisgroup.ch/g' argocd/application.yaml | kubectl apply -f -
```

Also apply the AnalysisTemplates:

```bash
kubectl apply -f argocd/analysis-templates.yaml
```

## 8. Verify

1. Push a commit to `main` — pipeline should trigger
2. Check GitLab CI/CD → Pipelines for build status
3. Check Harbor `idp` project for pushed images
4. Check ArgoCD for the `identity-portal` application
5. Verify `https://identity.aegisgroup.ch` loads the portal

## Troubleshooting

### Pipeline fails at build stage
- Verify `HARBOR_CI_USER` / `HARBOR_CI_PASSWORD` are set correctly
- Check that the `idp` project exists in Harbor
- Ensure GitLab runners have the Vault root CA trusted

### ArgoCD not syncing
- Verify the `deploy` branch exists and has the `k8s/` directory
- Check ArgoCD can access the GitLab repo (may need deploy key)
- Check `argocd app get identity-portal` for sync errors

### OIDC login fails
- Verify the Keycloak client secret matches what's in Vault
- Check ESO is syncing the secret: `kubectl get externalsecret -n identity-portal`
- Verify the OIDC issuer URL is reachable from the cluster

### Gateway/TLS issues
- Verify cert-manager has issued the certificate: `kubectl get certificate -n identity-portal`
- Check the Gateway is ready: `kubectl get gateway -n identity-portal`
- Verify Cilium L2 has announced the LoadBalancer IP
