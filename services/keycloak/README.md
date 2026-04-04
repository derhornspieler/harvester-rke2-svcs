# Keycloak Identity Service

Keycloak provides centralized OIDC-based identity and access management for the
platform. It replaces basic-auth on monitoring endpoints with SSO and serves as
the identity provider for all platform services.

## Architecture

```
                    Internet
                       |
                  [Traefik Gateway]
                  /       |       \
           keycloak.*   prom.*   alertmanager.*   hubble.*
               |          |          |               |
           [Keycloak]  [OAuth2-   [OAuth2-        [OAuth2-
            (2 pods)    Proxy]     Proxy]          Proxy]
               |          |          |               |
         [CNPG PG16]   [Prometheus] [Alertmanager] [Hubble UI]
         (3 instances)
```

### Components

| Component | Version | Replicas | Namespace |
|-----------|---------|----------|-----------|
| Keycloak | 26.0 | 2 (HPA: 2-5) | keycloak |
| PostgreSQL (CNPG) | 16.6 | 3 (1 primary + 2 replicas) | database |
| OAuth2-proxy (Prometheus) | v7.8.1 | 1 | monitoring |
| OAuth2-proxy (Alertmanager) | v7.8.1 | 1 | monitoring |
| OAuth2-proxy (Hubble) | v7.8.1 | 1 | kube-system |

### Identity Model

- **Single realm**: `platform` (configurable via `KC_REALM` env var)
- **Break-glass user**: `admin-breakglass` -- local user with temporary password,
  bypasses external IdP dependencies for emergency access
- **OIDC flow**: Authorization Code + PKCE (`code-challenge-method=S256`)
- **Session behavior**: `prompt=login` forces re-authentication on every login
  (no silent SSO), preventing stale sessions on shared workstations
- **Group-based RBAC**: Access controlled via Keycloak groups mapped to
  `groups` claim in OIDC tokens

### Groups

| Group | Access |
|-------|--------|
| `platform-admins` | Prometheus, Alertmanager, Hubble, Grafana, Harbor |
| `infra-engineers` | Prometheus, Alertmanager, Hubble |
| `network-engineers` | Hubble |

## Deployment

### Prerequisites

- Vault unsealed with PKI engine configured
- External Secrets Operator (ESO) running with `vault-backend` SecretStore
- CNPG operator deployed in `cnpg-system` namespace
- cert-manager with `vault-issuer` ClusterIssuer
- Traefik ingress controller (Gateway API)
- Valkey/Redis sentinel for OAuth2-proxy session storage

### Environment Variables

Set the following in `scripts/.env` (see `scripts/.env.example`):

```bash
KC_ADMIN_PASSWORD=""             # Keycloak bootstrap admin password
KEYCLOAK_DB_PASSWORD=""          # PostgreSQL password for keycloak user
KC_REALM="platform"              # Realm name (default: platform)
KEYCLOAK_BOOTSTRAP_CLIENT_SECRET=""  # Admin CLI client secret
BREAKGLASS_PASSWORD=""           # admin-breakglass user temporary password
```

### deploy-keycloak.sh (7 Phases)

```bash
./scripts/deploy-keycloak.sh
```

| Phase | Description |
|-------|-------------|
| 1 | Create `keycloak` namespace |
| 2 | Deploy ExternalSecrets (admin, postgres, OAuth2-proxy credentials from Vault) |
| 3 | Deploy PostgreSQL HA cluster (CNPG 3-instance) and scheduled daily backup |
| 4 | Deploy Keycloak core (ServiceAccount, RBAC, Services, Deployment, HPA) |
| 5 | Deploy Gateway and HTTPRoute for `keycloak.example.com` |
| 6 | Deploy OAuth2-proxy instances and Traefik ForwardAuth middleware |
| 7 | Deploy monitoring (ServiceMonitor, PrometheusRule alerts, Grafana dashboard) |

### setup-keycloak.sh (Post-Deploy, 6 Phases)

After Keycloak is running, configure the realm and OIDC clients:

```bash
./scripts/setup-keycloak.sh
```

| Phase | Description |
|-------|-------------|
| 1 | Create `platform` realm |
| 2 | Create OIDC client scopes (`groups` mapper, audience mapper) |
| 3 | Create OIDC clients for each protected service |
| 4 | Create groups (`platform-admins`, `infra-engineers`, `network-engineers`) |
| 5 | Create `admin-breakglass` user with temporary password |
| 6 | Verify realm configuration |

### OIDC Clients

| Client ID | Redirect URI | Protected Service |
|-----------|-------------|-------------------|
| `prometheus-oidc` | `https://prometheus.example.com/oauth2/callback` | Prometheus |
| `alertmanager-oidc` | `https://alertmanager.example.com/oauth2/callback` | Alertmanager |
| `hubble-oidc` | `https://hubble.example.com/oauth2/callback` | Hubble UI |
| `grafana-oidc` | `https://grafana.example.com/login/generic_oauth` | Grafana |
| `harbor-oidc` | `https://harbor.example.com/c/oidc/callback` | Harbor |

## OAuth2-Proxy Instances

Each OAuth2-proxy instance acts as a Traefik ForwardAuth middleware, intercepting
requests to the upstream service and redirecting unauthenticated users to Keycloak.

| Instance | Namespace | Upstream | Allowed Groups |
|----------|-----------|----------|----------------|
| `oauth2-proxy-prometheus` | monitoring | Prometheus | platform-admins, infra-engineers |
| `oauth2-proxy-alertmanager` | monitoring | Alertmanager | platform-admins, infra-engineers |
| `oauth2-proxy-hubble` | kube-system | Hubble UI | platform-admins, infra-engineers, network-engineers |

### Configuration

- **Provider**: `keycloak-oidc`
- **PKCE**: `code-challenge-method=S256`
- **Session store**: Redis Sentinel (Valkey)
- **Cookie**: Secure, SameSite=Lax, unique name per instance
- **CA trust**: Vault root CA mounted at `/etc/ssl/certs/vault-root-ca.pem`
- **Headers forwarded**: `X-Auth-Request-User`, `X-Auth-Request-Email`, `X-Auth-Request-Groups`

## Secrets Management

All secrets are stored in HashiCorp Vault and synced via ExternalSecrets:

| ExternalSecret | Namespace | Vault Path |
|----------------|-----------|------------|
| `keycloak-admin-secret` | keycloak | `services/keycloak/admin-secret` |
| `keycloak-postgres-secret` | keycloak | `services/keycloak/postgres-secret` |
| `keycloak-pg-credentials` | database | `services/database/keycloak-pg` |
| `oauth2-proxy-prometheus` | monitoring | `oidc/prometheus-oidc` |
| `oauth2-proxy-alertmanager` | monitoring | `oidc/alertmanager-oidc` |
| `oauth2-proxy-hubble` | kube-system | `oidc/hubble-oidc` |

## Monitoring

### ServiceMonitor

Scrapes Keycloak metrics from port 9000 (`/metrics`) every 30 seconds.

### Alerts (7 rules)

| Alert | Severity | Condition |
|-------|----------|-----------|
| `KeycloakDown` | critical | Instance unreachable for 5m |
| `KeycloakAllReplicasDown` | critical | All replicas down for 1m |
| `KeycloakHighServerErrorRate` | critical | >1 5xx/s for 5m |
| `KeycloakHighLoginFailureRate` | warning | >30% token request failures for 5m |
| `KeycloakHighTokenLatency` | warning | p99 token latency >2s for 5m |
| `KeycloakJvmHeapPressure` | warning | Heap usage >90% for 10m |
| `KeycloakHighGCPause` | warning | Average GC pause >500ms for 5m |

### Grafana Dashboard

A Keycloak Overview dashboard is auto-provisioned to the **Security** folder via
the `grafana-dashboard-keycloak` ConfigMap (label: `grafana_dashboard: "1"`).

## PostgreSQL

- **Cluster**: `keycloak-pg` (3 instances) in `database` namespace
- **Storage**: 10Gi on `harvester` StorageClass
- **Backup**: Daily at 02:15 UTC to MinIO (`s3://cnpg-backups/keycloak-pg`)
- **Node selector**: `workload-type: database`

## Verification

After deployment, verify the stack is healthy:

```bash
# Keycloak pods running
kubectl get pods -n keycloak -l app=keycloak

# PostgreSQL cluster healthy
kubectl get cluster keycloak-pg -n database

# Gateway and TLS certificate ready
kubectl get gateway keycloak -n keycloak
kubectl get certificate -n keycloak

# OAuth2-proxy pods running
kubectl get pods -n monitoring -l app.kubernetes.io/name=oauth2-proxy
kubectl get pods -n kube-system -l app.kubernetes.io/name=oauth2-proxy

# ExternalSecrets synced
kubectl get externalsecrets -n keycloak
kubectl get externalsecrets -n monitoring -l app.kubernetes.io/name=oauth2-proxy

# Keycloak health endpoint
kubectl exec -n keycloak deploy/keycloak -- curl -sf http://localhost:9000/health/ready

# OIDC discovery endpoint (from outside cluster)
curl -sf https://keycloak.example.com/realms/platform/.well-known/openid-configuration | jq .
```
