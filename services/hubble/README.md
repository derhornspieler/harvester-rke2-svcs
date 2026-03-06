# Hubble UI — Cilium Network Observability Dashboard

Hubble UI provides a graphical interface to explore network flows, policies, and service dependencies observed by Cilium. This directory configures external access to the Hubble UI running in the `kube-system` namespace.

## Architecture

### Components

- **Hubble UI Pod**: Deployed in `kube-system` namespace by Cilium HelmChartConfig, listens on port 80 (HTTP)
- **Gateway**: `services/hubble/gateway.yaml` — Listens on 443 (HTTPS), routes to OAuth2-proxy
- **HTTPRoute**: `services/hubble/httproute.yaml` — Splits traffic:
  - `/oauth2/*` → OAuth2-proxy (4180)
  - `/*` → Hubble UI (80), protected by OAuth2-proxy ForwardAuth middleware
- **OAuth2-proxy**: Deployed in `keycloak` namespace, validates OIDC tokens against Keycloak before proxying requests
- **TLS Certificate**: Issued by cert-manager from Vault intermediate CA

### Access Flow

```
User Browser
    ↓
GET https://hubble.dev.example.com
    ↓
Traefik (kube-system)
    ↓
Gateway (hubble, 443 HTTPS)
    ↓
HTTPRoute (hubble)
    ├→ ForwardAuth Middleware (oauth2-proxy-hubble)
    │   └→ OAuth2-proxy (keycloak:4180)
    │       └→ Keycloak OIDC validation
    ├→ /oauth2/* → OAuth2-proxy (handles login/callback)
    └→ /* → Hubble UI (kube-system:80) [if authenticated]
```

## Configuration Files

### Gateway (services/hubble/gateway.yaml)

Defines the HTTPS listener:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: hubble
  namespace: kube-system
spec:
  gatewayClassName: traefik
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - name: hubble-cert   # Created by cert-manager
            namespace: kube-system
```

**Key points:**

- Class: `traefik` (RKE2 default)
- Listens on 443 with HTTPS termination
- TLS certificate from `kube-system` namespace (managed by cert-manager)

### HTTPRoute (services/hubble/httproute.yaml)

Routes requests based on path:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: hubble
  namespace: kube-system
spec:
  parentRefs:
    - name: hubble         # References Gateway above
      namespace: kube-system
      sectionName: https
  hostnames:
    - "hubble.dev.example.com"
  rules:
    # OAuth2-proxy endpoints (handle login/callback without auth)
    - matches:
        - path:
            type: PathPrefix
            value: /oauth2
      backendRefs:
        - name: oauth2-proxy-hubble
          port: 4180

    # Hubble UI (protected by ForwardAuth middleware)
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: oauth2-proxy-hubble
      backendRefs:
        - name: hubble-ui
          port: 80
```

**Key points:**

- Hostname: `hubble.dev.example.com` (placeholder: `CHANGEME_DOMAIN`)
- Path `/oauth2/*` routed directly to OAuth2-proxy (login/callback flow)
- Path `/*` routed to Hubble UI with ForwardAuth middleware (validates session)

## Deployment & Prerequisites

### Prerequisites

Before deploying Hubble UI, these must be complete:

1. **Bundle 1 (PKI & Secrets)**:
   - Vault unsealed with PKI intermediate CA configured
   - cert-manager controller running, Issuer configured

2. **Bundle 2 (Identity)**:
   - Keycloak running with realm configured
   - Hubble OIDC client created (redirect_uri: `https://hubble.dev.example.com/oauth2/callback`)
   - OAuth2-proxy-hubble Secret synced from Vault via ESO

3. **Cilium/Hubble enabled** (via RKE2 HelmChartConfig):
   - Hubble relay running (2 replicas)
   - Hubble UI pod running (`kube-system` namespace)

### Deployment Steps

This is configured as part of Bundle 3 (Monitoring) bootstrap:

1. **Apply Gateway and HTTPRoute**:
   ```bash
   kubectl apply -f services/hubble/gateway.yaml
   kubectl apply -f services/hubble/httproute.yaml
   ```

2. **Verify Gateway is ready**:
   ```bash
   kubectl -n kube-system get gateway hubble
   kubectl -n kube-system describe gateway hubble
   ```

3. **Verify HTTPRoute is ready**:
   ```bash
   kubectl -n kube-system get httproute hubble
   ```

4. **Verify TLS certificate**:
   ```bash
   kubectl -n kube-system get certificate hubble-cert
   kubectl -n kube-system get secret hubble-cert
   ```

5. **Test access**:
   ```bash
   curl -k https://hubble.dev.example.com/
   # Should redirect to Keycloak login
   ```

## Troubleshooting

### Gateway Not Ready

**Symptom**: `kubectl describe gateway hubble` shows "not ready"

**Check:**

```bash
# Verify Traefik class exists
kubectl get gatewayclasses

# Verify TLS certificate secret exists
kubectl -n kube-system get secret hubble-cert

# Check cert-manager issued the certificate
kubectl -n kube-system get certificate hubble-cert -o yaml
```

**Common causes:**

- TLS certificate not issued (check cert-manager logs)
- Gateway class mismatch (must be `traefik` on RKE2)

### HTTPRoute Not Routing

**Symptom**: Requests to `https://hubble.dev.example.com` return 503 or connection refused

**Check:**

```bash
# Verify HTTPRoute is bound
kubectl -n kube-system get httproute hubble -o yaml

# Verify backend services exist and have endpoints
kubectl -n kube-system get svc hubble-ui oauth2-proxy-hubble
kubectl -n kube-system get endpoints hubble-ui oauth2-proxy-hubble

# Check Traefik ingress logs
kubectl -n kube-system logs -l app=traefik | grep hubble
```

**Common causes:**

- Hubble UI service or OAuth2-proxy service not running
- HTTPRoute parentRef doesn't match Gateway name/section
- Service ports mismatch (HTTPRoute port != Service targetPort)

### OAuth2-proxy ForwardAuth Not Working

**Symptom**: Requests to UI return 401/403, or loop back to login page

**Check:**

```bash
# Verify OAuth2-proxy pod is running
kubectl -n keycloak get pods -l app=oauth2-proxy-hubble

# Check OAuth2-proxy logs for OIDC errors
kubectl -n keycloak logs -l app=oauth2-proxy-hubble | grep -i error

# Verify ExternalSecret synced credentials
kubectl -n keycloak get secret oauth2-proxy-hubble-oidc
kubectl -n keycloak get externalsecret oauth2-proxy-hubble-oidc

# Verify Keycloak Hubble client is configured
kubectl -n keycloak exec -it <keycloak-pod> -- \
  bash -c 'cd /opt/keycloak && bin/kcadm.sh get clients -r aegis --username admin'
```

**Common causes:**

- OAuth2-proxy credentials not synced (ESO issue, check Vault kv/services/oauth2-proxy-hubble)
- Keycloak Hubble client not created or redirect_uri mismatch
- Middleware name in HTTPRoute doesn't match actual Middleware resource
- Network connectivity issue between namespaces (verify `keycloak → kube-system:80`)

### Hubble UI Shows "No Data" or Empty Flows

**Symptom**: UI loads but network flows are not displayed

This is a Hubble relay/metrics issue, not a UI ingress issue. See `services/cilium/README.md` troubleshooting section.

## RBAC

Hubble UI pod runs with minimal permissions (no special RBAC needed for UI).

OAuth2-proxy requires read-only access to Keycloak and network access to identity provider.

## Customization

### Changing Hostname

To use a different hostname (e.g., `network-visibility.dev.example.com`):

1. Update Gateway TLS certificate hostname (cert-manager annotation on Gateway or separate Certificate resource)
2. Update HTTPRoute `hostnames` field
3. Update OAuth2-proxy Keycloak client `redirectUris`
4. Ensure DNS resolves new hostname to Traefik

### Adjusting Resource Limits

To increase Hubble UI resource allocation:

1. Edit the HelmChartConfig in `services/cilium/helmchartconfig.yaml`:
   ```yaml
   hubble:
     ui:
       resources:
         requests:
           cpu: 50m       # Increase from 25m
           memory: 64Mi   # Increase from 32Mi
   ```

2. Apply the config to RKE2:
   ```bash
   kubectl apply -f services/cilium/helmchartconfig.yaml
   ```

## Related Services

- **Cilium/Hubble** (`services/cilium/`) — HelmChartConfig, metrics, alerts, dashboard
- **OAuth2-proxy** (`services/keycloak/oauth2-proxy/hubble.yaml`) — Authentication proxy
- **Keycloak** (`services/keycloak/`) — OIDC identity provider
- **Traefik** (`kube-system`) — Ingress controller and Gateway API implementation
- **cert-manager** (`cert-manager`) — Issues TLS certificates for Gateway

## See Also

- **Cilium Architecture**: `services/cilium/README.md`
- **Full Monitoring Stack**: `services/monitoring-stack/` (Prometheus, Grafana, Loki, Alloy)
- **Gateway API Docs**: `docs/architecture.md` — Network ingress strategy
- **OAuth2-proxy Checklist**: `memory/teams/dev.md` — Per-service OIDC setup pattern
