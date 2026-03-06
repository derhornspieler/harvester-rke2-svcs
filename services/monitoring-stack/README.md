# Monitoring Stack

Full observability stack: metrics (Prometheus), dashboards (Grafana), logs (Loki), log collection (Alloy).

## Architecture

- **Prometheus** — metrics collection, 30-day retention, 50Gi PVC, auto-scaling via VolumeAutoscaler
- **Grafana** — 18 dashboards (15 platform + 3 from Bundle 1), HPA 2-4 replicas, native OIDC (Bundle 2)
- **Alertmanager** — alert routing (critical/warning/default receivers), HTTP listener on port 9093
- **Loki** — log aggregation, 30-day retention (720h), TSDB v13, auto-scaling via VolumeAutoscaler, startupProbe for graceful initialization, hardened securityContext (non-root, read-only filesystem)
- **Alloy** — DaemonSet log collector (pod logs, journal, K8s events)

## Deployment

    ./scripts/deploy-monitoring.sh

### Required Environment Variables

Set these in `scripts/.env` before deployment:

| Variable | Purpose | Example |
|----------|---------|---------|
| `DOMAIN` | Cluster domain for all URLs | `example.com` |
| `GRAFANA_ADMIN_PASSWORD` | Initial admin login password | `SecurePassword123!` |
| `PROM_BASIC_AUTH_PASS` | Prometheus HTTP basic-auth password | `admin-secret` |
| `AM_BASIC_AUTH_PASS` | Alertmanager HTTP basic-auth password | `admin-secret` |
| `PROM_BASIC_AUTH_USER` | Prometheus username (optional, default: `admin`) | `prometheus-user` |
| `AM_BASIC_AUTH_USER` | Alertmanager username (optional, default: `admin`) | `alertmanager-user` |

Optional Helm chart overrides:
- `HELM_CHART_PROMETHEUS_STACK` — Override chart source (e.g., for Harbor OCI registry)
- `HELM_REPO_PROMETHEUS_STACK` — Override Helm repository URL

## Ingress

| Service | URL | Auth |
|---------|-----|------|
| Grafana | `https://grafana.<DOMAIN>` | Built-in login |
| Prometheus | `https://prometheus.<DOMAIN>` | Basic-auth (admin/admin) |
| Alertmanager | `https://alertmanager.<DOMAIN>` | Basic-auth (admin/admin) |

Basic-auth is a placeholder — replaced by Keycloak OIDC in Bundle 2.

## Dashboards (18)

Home, Firing Alerts, etcd, API Server, Node Detail, Traefik, CoreDNS, Cilium,
CNPG, Redis, Loki, Loki Stack, Alloy, OAuth2-proxy, Cluster Autoscaler,
Vault, cert-manager, ESO.

## Alert Groups (9)

Kubernetes, Cilium, Loki, Monitoring Self, Node, Traefik, PostgreSQL, Redis, OAuth2-proxy.

## Service Ports

- **Grafana**: 3000 (HTTP)
- **Prometheus**: 9090 (HTTP)
- **Alertmanager**: 9093 (HTTP)
- **Loki**: 3100 (HTTP)
- **Alloy**: 12345 (HTTP)

## Verify

    ./scripts/deploy-monitoring.sh --validate
