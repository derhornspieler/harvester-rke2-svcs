# Troubleshooting

This guide covers common issues developers encounter on the platform and how
to debug them. All commands assume you have `kubectl` configured with access
to the target namespace.

---

## 1. Image Pull Failures

### Symptoms

Pod stuck in `ImagePullBackOff` or `ErrImagePull`.

### Debug steps

```bash
# Check pod events for the exact error
kubectl describe pod <POD> -n <NS> | tail -30
```

Look for one of these event messages:

| Event message | Cause | Fix |
|---------------|-------|-----|
| `repository does not exist` | Harbor project missing | Create the project in Harbor UI at `harbor.dev.<DOMAIN>` |
| `manifest unknown` | Tag does not exist | Verify the tag was pushed: check CI pipeline artifacts |
| `unauthorized: authentication required` | Robot account missing or expired | Create/renew a robot account in the Harbor project |
| `dial tcp: lookup harbor.dev.<DOMAIN>: no such host` | DNS not resolving | Check that your pod network can reach Harbor (CoreDNS issue) |

### Verify the image exists in Harbor

```bash
# From your workstation (with Harbor credentials)
docker login harbor.dev.<DOMAIN>
docker manifest inspect harbor.dev.<DOMAIN>/<TEAM>/<APP>:<TAG>
```

If the image is missing, re-run the CI pipeline or push manually:

```bash
docker tag <APP>:<TAG> harbor.dev.<DOMAIN>/<TEAM>/<APP>:<TAG>
docker push harbor.dev.<DOMAIN>/<TEAM>/<APP>:<TAG>
```

### Common mistakes

- Using `harbor.<DOMAIN>` (pull-through cache) instead of `harbor.dev.<DOMAIN>`
  (in-cluster registry) in your deployment manifests.
- Missing the project prefix: `harbor.dev.<DOMAIN>/<APP>:<TAG>` instead of
  `harbor.dev.<DOMAIN>/<TEAM>/<APP>:<TAG>`.
- Using `:latest` tag -- always pin to a specific semver or digest.

---

## 2. Pod CrashLoopBackOff

### Debug steps

```bash
# Check current pod status and restart count
kubectl get pods -n <NS> -l app=<APP>

# View logs from the most recent crash
kubectl logs <POD> -n <NS> --previous

# View current container logs (if the pod is still running)
kubectl logs <POD> -n <NS> -f
```

### Common causes

#### Missing environment variables or secrets

```bash
# Check if all expected env vars are set
kubectl exec <POD> -n <NS> -- env | sort

# Check if referenced secrets/configmaps exist
kubectl get secret -n <NS>
kubectl get configmap -n <NS>
```

If a Secret is managed by ESO and missing, see
[Section 3: Secret Sync Failures](#3-secret-sync-failures-eso).

#### Database connection failed

Logs typically show `connection refused` or `FATAL: password authentication
failed`. Verify:

```bash
# Check if the database service is reachable from the pod
kubectl exec <POD> -n <NS> -- nc -zv <DB_HOST> <DB_PORT>
```

Ensure the database credentials in Vault match what the application expects.

#### OOMKilled

```bash
# Check for OOMKilled in the last restart reason
kubectl get pod <POD> -n <NS> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
```

If the output is `OOMKilled`, increase the memory request in your deployment
manifest. This platform uses **requests only (no limits)** -- the request value
determines the node scheduling guarantee, but the container can burst above it.
OOMKilled means the node itself ran out of memory. Increase the request so the
scheduler places the pod on a node with sufficient headroom.

```yaml
resources:
  requests:
    memory: "512Mi"   # increase from previous value
    cpu: "250m"
```

#### Health check misconfiguration

```bash
# Check which probes are configured
kubectl get pod <POD> -n <NS> -o jsonpath='{.spec.containers[0].livenessProbe}' | jq .
kubectl get pod <POD> -n <NS> -o jsonpath='{.spec.containers[0].readinessProbe}' | jq .
```

Common issues:
- Wrong path (e.g., `/healthz` vs `/health` vs `/ready`)
- Wrong port (container port doesn't match probe port)
- `initialDelaySeconds` too short for slow-starting apps (increase to 30-60s)

---

## 3. Secret Sync Failures (ESO)

### Check ExternalSecret status

```bash
# List all ExternalSecrets and their sync status
kubectl get externalsecrets -n <NS>

# Expected output when healthy:
# NAME          STORE          REFRESH INTERVAL   STATUS
# app-secrets   vault-store    5m                 SecretSynced
```

If the STATUS column shows `SecretSyncedError`:

```bash
# Get the detailed error
kubectl describe externalsecret <NAME> -n <NS>
```

### Common errors

| Error message | Cause | Fix |
|---------------|-------|-----|
| `could not get secret data from provider` | Vault path does not exist | Create the secret in Vault at the expected path |
| `could not find SecretStore` | Wrong SecretStore name in the ExternalSecret | Verify the SecretStore exists: `kubectl get secretstores -n <NS>` |
| `forbidden` or `permission denied` | Vault role not authorized for path | Check the Vault policy attached to the namespace's AppRole |
| `connection refused` | Vault is sealed or unreachable | Contact platform team -- Vault may need unsealing |

### Verify the Vault path exists

Ask a platform admin to confirm the expected secret path exists:

```
kv/services/<SERVICE>/<SECRET_NAME>
```

### RefreshInterval

Always use `refreshInterval: 5m` in your ExternalSecret. ESO caches failures
with exponential backoff -- a long interval (e.g., 1h) means you wait a long
time for recovery after fixing the underlying issue.

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: app-secrets
  namespace: <NS>
spec:
  refreshInterval: 5m
  secretStoreRef:
    name: vault-store
    kind: SecretStore
  target:
    name: app-secrets
  data:
    - secretKey: DATABASE_PASSWORD
      remoteRef:
        key: kv/services/<SERVICE>/db
        property: password
```

### Force a sync

```bash
# Annotate the ExternalSecret to trigger an immediate reconciliation
kubectl annotate externalsecret <NAME> -n <NS> \
  force-sync=$(date +%s) --overwrite
```

---

## 4. ArgoCD Deployment Issues

### Check application status

```bash
# List your applications (requires argocd CLI)
argocd app list --project <TEAM>

# Get detailed status for a specific application
argocd app get <TEAM>-<APP>
```

Or use the ArgoCD UI at `https://argo.<DOMAIN>`.

### App stuck in "Progressing"

This usually means pods are not reaching a Ready state.

```bash
# Check pod events in the target namespace
kubectl get pods -n <NS>
kubectl describe pod <POD> -n <NS>
```

Common causes: image pull failures (Section 1), CrashLoopBackOff (Section 2),
or pending PVCs.

### OutOfSync

The live state differs from what is in Git.

```bash
# View the diff between live and desired state
argocd app diff <TEAM>-<APP>
```

If someone manually edited a resource with `kubectl`, ArgoCD will detect drift.
Fix the manifests in Git and let ArgoCD sync -- do not patch resources manually.

### SyncFailed

```bash
# Check sync result details
argocd app get <TEAM>-<APP> -o json | jq '.status.operationState.syncResult.resources[] | select(.status != "Synced")'
```

Common causes:
- Invalid YAML / missing required fields -- validate with `kubectl apply --dry-run=client -f <FILE>`
- Namespace doesn't exist -- ensure ArgoCD is configured to create it
- Immutable field changed (e.g., Service `clusterIP`) -- delete the resource and let ArgoCD recreate it

### Image tag not updating

If you pushed a new image but ArgoCD still deploys the old tag:

1. Verify the CI deploy stage updated the tag in `platform-deployments`:
   ```bash
   # Check the kustomization.yaml in the platform-deployments repo
   git -C /path/to/platform-deployments log --oneline -5
   ```
2. Verify ArgoCD has detected the commit (check "Last Synced" in the UI).
3. If auto-sync is enabled, wait up to 3 minutes for the sync interval.
4. If manual sync, trigger it: `argocd app sync <TEAM>-<APP>`.

---

## 5. CI Pipeline Failures

### Vault JWT auth failed

The CI pipeline uses Vault JWT authentication. If the `vault:login` step fails:

```
Error: permission denied
```

Check your `.gitlab-ci.yml`:

```yaml
# The id_tokens block is REQUIRED for Vault JWT auth
job_name:
  id_tokens:
    VAULT_ID_TOKEN:
      aud: https://vault.<DOMAIN>
  secrets:
    DATABASE_PASSWORD:
      vault: kv/services/<SERVICE>/db/password@secrets
      token: $VAULT_ID_TOKEN
```

Common mistakes:
- Missing `id_tokens` block entirely (GitLab won't generate a JWT)
- Wrong `aud` value -- must match the Vault JWT auth backend audience
- Vault role not bound to the GitLab project path

### Harbor push denied

```
denied: requested access to the resource is denied
```

Verify:
1. The Harbor project exists at `harbor.dev.<DOMAIN>` (create it if not).
2. The CI robot account has push permission on the project.
3. The robot account credentials in Vault are current.

```yaml
# In .gitlab-ci.yml -- use Vault-injected credentials
build:
  script:
    - docker login -u "$HARBOR_ROBOT_USER" -p "$HARBOR_ROBOT_TOKEN" harbor.dev.<DOMAIN>
    - docker push harbor.dev.<DOMAIN>/<TEAM>/<APP>:$CI_COMMIT_SHORT_SHA
```

### Deploy stage failed

The deploy stage updates manifests in `platform-deployments`. Common failures:

| Error | Cause | Fix |
|-------|-------|-----|
| `Permission denied (publickey)` | SSH deploy key missing | Verify `kv/ci/deploy-key` exists in Vault and the public key is added to the platform-deployments repo |
| `fatal: path '<TEAM>/<APP>' does not exist` | Directory not scaffolded | Create the directory structure in platform-deployments first (see the ArgoCD deployment guide) |
| `remote: GitLab: You are not allowed to push` | Wrong deploy key permissions | Ensure the deploy key has **write** access, not just read |

### Build cache miss

If every build downloads dependencies from scratch:

1. Verify the `ci-cache` project exists in Harbor.
2. Check that the CI runner has pull/push access to `harbor.dev.<DOMAIN>/ci-cache/`.
3. Ensure your `.gitlab-ci.yml` uses the correct cache key and paths.

---

## 6. TLS Certificate Issues

### Check certificate status

```bash
# List certificates and their readiness
kubectl get certificates -n <NS>

# Expected output when healthy:
# NAME         READY   SECRET       AGE
# app-tls      True    app-tls      5d
```

If READY is `False`:

```bash
# Check the Certificate resource for errors
kubectl describe certificate <NAME> -n <NS>

# Check the associated CertificateRequest
kubectl get certificaterequest -n <NS>
kubectl describe certificaterequest <NAME> -n <NS>
```

### Common errors

| Symptom | Cause | Fix |
|---------|-------|-----|
| `issuer not found` | Wrong ClusterIssuer name | Use `vault-issuer` (the only ClusterIssuer on this platform) |
| `forbidden: ... not authorized` | Vault PKI role doesn't allow the domain | Contact platform team to add the domain to the Vault PKI role |
| Certificate never becomes Ready | cert-manager can't reach Vault | Check that Vault is unsealed and the cert-manager ServiceAccount has a valid token |

### Verify your Certificate manifest

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: app-tls
  namespace: <NS>
spec:
  secretName: app-tls
  issuerRef:
    name: vault-issuer
    kind: ClusterIssuer
  commonName: <APP>.<DOMAIN>
  dnsNames:
    - <APP>.<DOMAIN>
```

### Certificate renewal

Certificates are automatically renewed by cert-manager before expiry. If a
certificate is expired, delete the Secret and cert-manager will re-issue:

```bash
kubectl delete secret <SECRET_NAME> -n <NS>
# cert-manager will detect the missing secret and re-issue automatically
```

---

## 7. Network / Gateway API Issues

### 404 Not Found from Traefik

The request reached Traefik but no HTTPRoute matched.

```bash
# List HTTPRoutes in your namespace
kubectl get httproutes -n <NS>

# Check the HTTPRoute details
kubectl describe httproute <NAME> -n <NS>
```

Common causes:
- Hostname in the HTTPRoute doesn't match the request hostname
- Path prefix doesn't match (e.g., `/api` vs `/api/`)
- HTTPRoute references a Gateway that doesn't exist or doesn't allow the namespace

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: app-route
  namespace: <NS>
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik
  hostnames:
    - "<APP>.<DOMAIN>"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: <APP>-svc
          port: 8080
```

### 502 Bad Gateway

Traefik matched the route but the backend is unavailable.

```bash
# Check if the backend service exists and has endpoints
kubectl get endpoints <APP>-svc -n <NS>

# If ENDPOINTS is <none>, no pods are matching the service selector
kubectl get pods -n <NS> -l app=<APP>
```

Common causes:
- Pod is not Ready (check readiness probe)
- Service port doesn't match the container port
- Service selector labels don't match pod labels

```bash
# Compare service selector with pod labels
kubectl get svc <APP>-svc -n <NS> -o jsonpath='{.spec.selector}'
kubectl get pod <POD> -n <NS> -o jsonpath='{.metadata.labels}'
```

### OAuth2-proxy 500 errors

If your application uses OAuth2-proxy for Keycloak authentication and you see
a 500 error after login:

1. **Clear browser cookies** for the domain -- stale session cookies are the
   most common cause.
2. If the error persists, check OAuth2-proxy logs:
   ```bash
   kubectl logs -n <NS> -l app=oauth2-proxy --tail=50
   ```
3. Verify the Keycloak client configuration:
   - Redirect URIs include `https://<APP>.<DOMAIN>/oauth2/callback`
   - Post-logout redirect URIs include `https://<APP>.<DOMAIN>/*`

---

## General Debugging Checklist

When nothing else works, run through this checklist:

```bash
# 1. Pod status and events
kubectl get pods -n <NS>
kubectl describe pod <POD> -n <NS>

# 2. Logs (current and previous crash)
kubectl logs <POD> -n <NS>
kubectl logs <POD> -n <NS> --previous

# 3. Resource consumption
kubectl top pods -n <NS>

# 4. Network connectivity from inside the pod
kubectl exec <POD> -n <NS> -- wget -qO- http://localhost:<PORT>/health

# 5. DNS resolution
kubectl exec <POD> -n <NS> -- nslookup <SERVICE_HOST>

# 6. Events in the namespace (sorted by time)
kubectl get events -n <NS> --sort-by=.lastTimestamp | tail -20
```

If you are stuck, open an issue in the platform team's GitLab project with:
- Namespace and pod name
- Output of `kubectl describe pod`
- Application logs (`kubectl logs --previous`)
- What you have already tried
