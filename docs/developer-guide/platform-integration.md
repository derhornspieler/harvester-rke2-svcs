# Platform Integration Guide

How to integrate your application with platform services: authentication,
secrets, metrics, logging, and container registry.

**Prerequisites**: your app is deployed to a platform-managed namespace, a
SecretStore CR exists in that namespace (created by init jobs), and you have
GitLab/Harbor access via Keycloak SSO.

---

## 1. Keycloak OIDC Authentication

All user-facing services authenticate through Keycloak OIDC. The platform
realm is `platform`, exposed at:

```
https://keycloak.<DOMAIN>/realms/platform
```

### Requesting an OIDC Client

OIDC clients are created by the platform team via Keycloak init jobs. To
request one, provide:

| Field | Example | Notes |
|-------|---------|-------|
| Client ID | `<TEAM>-<APP>` | Lowercase, hyphenated |
| Redirect URIs | `https://<APP>.<DOMAIN>/callback` | Exact match, no wildcards |
| Post-logout URIs | `https://<APP>.<DOMAIN>/*` | Explicit wildcard required |
| Scopes | `openid profile email groups` | `groups` for RBAC |

The client secret is stored in Vault at `kv/services/<APP>/oidc-client-secret`
and read via ESO (see section 2). Auto-configure your OIDC library with the
discovery endpoint:

```
https://keycloak.<DOMAIN>/realms/platform/.well-known/openid-configuration
```

### Example: Go JWT Validation Middleware

```go
package auth

import (
    "context"
    "net/http"
    "github.com/coreos/go-oidc/v3/oidc"
)

func OIDCMiddleware(issuerURL, clientID string) func(http.Handler) http.Handler {
    provider, _ := oidc.NewProvider(context.Background(), issuerURL)
    verifier := provider.Verifier(&oidc.Config{ClientID: clientID})

    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            raw := r.Header.Get("Authorization")
            if len(raw) < 8 || raw[:7] != "Bearer " {
                http.Error(w, "missing bearer token", http.StatusUnauthorized)
                return
            }
            idToken, err := verifier.Verify(r.Context(), raw[7:])
            if err != nil {
                http.Error(w, "invalid token", http.StatusUnauthorized)
                return
            }
            // Extract groups claim for RBAC
            var claims struct{ Groups []string `json:"groups"` }
            _ = idToken.Claims(&claims)
            ctx := context.WithValue(r.Context(), "groups", claims.Groups)
            next.ServeHTTP(w, r.WithContext(ctx))
        })
    }
}

// Usage:
// mux.Handle("/api/", auth.OIDCMiddleware(
//     "https://keycloak.<DOMAIN>/realms/platform", "<TEAM>-<APP>",
// )(apiHandler))
```

### Example: Frontend Redirect to Keycloak Login

For browser-based apps, redirect to the authorization endpoint:

```javascript
function redirectToLogin() {
  const params = new URLSearchParams({
    client_id: "<TEAM>-<APP>",
    redirect_uri: "https://<APP>.<DOMAIN>/callback",
    response_type: "code",
    scope: "openid profile email groups",
  });
  window.location.href =
    "https://keycloak.<DOMAIN>/realms/platform/protocol/openid-connect/auth?" + params;
}
```

### Groups Claim for RBAC

Request the `groups` scope to receive group memberships in the ID token as a
string array (e.g., `["/platform-admins", "/dev-team"]`). Map groups to
application roles in your authorization logic -- do not hardcode group names.

---

## 2. Vault Secrets via ESO

Secrets are stored in Vault KV v2 under `kv/services/<APP>`. The External
Secrets Operator (ESO) syncs them into Kubernetes Secrets automatically.

### ExternalSecret Example

Each namespace has a pre-configured `SecretStore` named `vault-backend`.
Create an `ExternalSecret` to pull values:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: <APP>-secrets
  namespace: <TEAM>-<APP>
spec:
  refreshInterval: 5m
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: <APP>-secrets
    creationPolicy: Owner
  data:
    - secretKey: database-password
      remoteRef:
        key: kv/services/<APP>
        property: database-password
    - secretKey: oidc-client-secret
      remoteRef:
        key: kv/services/<APP>
        property: oidc-client-secret
```

Mount the resulting Secret via `envFrom: [{secretRef: {name: <APP>-secrets}}]`.

**Do not set `refreshInterval` to `1h`** -- ESO caches failures with
exponential backoff. At `1h`, recovery can take hours. Use `5m`.

### PushSecret for Writing Back to Vault

If your app generates credentials other services need, use a `PushSecret` CR
that references `vault-backend` and maps a local Secret key to a Vault path
(`kv/services/<APP>/<property>`). Your namespace's Vault AppRole must have
`create`/`update` capabilities -- request this from the platform team.

---

## 3. Prometheus Metrics

Expose a `/metrics` endpoint and create a ServiceMonitor to register it.

### ServiceMonitor Example

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: <APP>-metrics
  namespace: <TEAM>-<APP>
  labels:
    release: kube-prometheus-stack    # required for Prometheus to discover it
spec:
  selector:
    matchLabels:
      app: <APP>
  endpoints:
    - port: metrics          # must match the Service port name
      path: /metrics
      interval: 30s
```

Your Service must expose a named port matching the `port` field above (e.g.,
`name: metrics, port: 9090`).

### Common Metric Types

| Type | Use Case | Example |
|------|----------|---------|
| Counter | Monotonically increasing values | `http_requests_total` |
| Gauge | Values that go up and down | `active_connections` |
| Histogram | Distribution of values (latency) | `http_request_duration_seconds` |

Follow Prometheus naming conventions: `<app>_<name>_<unit>_total` for
counters, `<app>_<name>_<unit>` for gauges and histograms.

### Grafana Dashboard ConfigMap

To auto-provision a Grafana dashboard, create a ConfigMap in the `monitoring`
namespace with the label `grafana_dashboard: "1"`. Put your dashboard JSON
under `data.<APP>.json`. Grafana's sidecar discovers labeled ConfigMaps
across all namespaces. Export dashboards from the Grafana UI and paste the
JSON into the ConfigMap for production use.

---

## 4. Structured Logging for Loki

Alloy collects logs from all pods and ships them to Loki. Write structured
JSON logs so they are queryable in Grafana.

### Required Log Format

```json
{"level":"info","msg":"request handled","ts":"2026-03-28T10:15:30Z","method":"GET","path":"/api/items","status":200,"duration_ms":42,"correlation_id":"abc-123"}
```

| Field | Required | Description |
|-------|----------|-------------|
| `level` | Yes | `debug`, `info`, `warn`, `error` |
| `msg` | Yes | Human-readable message |
| `ts` | Yes | ISO 8601 / RFC 3339 timestamp |
| `correlation_id` | Recommended | Trace ID for request correlation |

Avoid multi-line log messages -- they break log parsing. Encode stack traces
as a single JSON field (`"stack":"main.go:42 > handler.go:17"`).

### Correlation IDs

Generate a correlation ID at the entry point of each request. If the incoming
request has an `X-Correlation-ID` header, reuse it; otherwise generate a UUID.
Propagate it in context and set it on the response:

```go
func correlationMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        id := r.Header.Get("X-Correlation-ID")
        if id == "" { id = uuid.NewString() }
        ctx := context.WithValue(r.Context(), "correlation_id", id)
        w.Header().Set("X-Correlation-ID", id)
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}
```

### LogQL Query Examples

```logql
{namespace="<TEAM>-<APP>"} | json | level="error"              # all errors
{namespace="<TEAM>-<APP>"} | json | duration_ms > 500           # slow requests
{namespace=~"<TEAM>-.*"} | json | correlation_id="abc-123"      # trace a request
sum(rate({namespace="<TEAM>-<APP>"} | json | level="error" [5m])) # error rate
```

---

## 5. Harbor Container Registry

Images are stored at `harbor.dev.<DOMAIN>/<TEAM>/<APP>`, organized by team
project (created by the platform team on request).

### CI Pushes (Automated)

GitLab CI pipelines push images via a robot account (`HARBOR_USER` /
`HARBOR_PASSWORD` CI/CD variables, set at the group level by platform team):

```yaml
build-image:
  stage: build
  image: harbor.dev.<DOMAIN>/proxy-cache/library/docker:27
  services:
    - name: harbor.dev.<DOMAIN>/proxy-cache/library/docker:27-dind
      alias: docker
  script:
    - echo "${HARBOR_PASSWORD}" | docker login harbor.dev.<DOMAIN> -u "${HARBOR_USER}" --password-stdin
    - docker build -t harbor.dev.<DOMAIN>/<TEAM>/<APP>:${CI_COMMIT_SHORT_SHA} .
    - docker push harbor.dev.<DOMAIN>/<TEAM>/<APP>:${CI_COMMIT_SHORT_SHA}
```

### Local Development

Authenticate via Keycloak OIDC: `docker login harbor.dev.<DOMAIN>` using your
Keycloak username and password (or CLI secret from the Harbor UI).

### Image Tagging Policy

- Pin to a specific tag or digest -- never use `latest`
- CI builds: `<TEAM>/<APP>:${CI_COMMIT_SHORT_SHA}`
- Releases: `<TEAM>/<APP>:1.2.3`

---

## Quick Reference

| Service | URL | Integration Method |
|---------|-----|--------------------|
| Keycloak | `https://keycloak.<DOMAIN>/realms/platform` | OIDC discovery |
| Vault | `kv/services/<APP>` | ExternalSecret CR |
| Prometheus | In-cluster scrape | ServiceMonitor CR |
| Grafana | `https://grafana.<DOMAIN>` | Dashboard ConfigMap |
| Loki | In-cluster via Alloy | Structured JSON logs |
| Harbor | `harbor.dev.<DOMAIN>` | docker login / CI robot |

## Further Reading

- [Authentication and Identity](../architecture/authentication-identity.md)
- [Secrets and Configuration](../architecture/secrets-configuration.md)
- [Observability and Monitoring](../architecture/observability-monitoring.md)
- [CI/CD Pipeline](../architecture/cicd-pipeline.md)
