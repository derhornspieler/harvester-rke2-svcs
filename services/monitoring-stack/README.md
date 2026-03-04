# Monitoring Stack

Full observability stack: metrics (Prometheus), dashboards (Grafana), logs (Loki), log collection (Alloy).

## Architecture

- **Prometheus** — metrics collection, 30-day retention, 50Gi PVC
- **Grafana** — 18 dashboards (15 platform + 3 from Bundle 1), native OIDC (Bundle 4)
- **Alertmanager** — alert routing (critical/warning/default receivers)
- **Loki** — log aggregation, 7-day retention, TSDB v13
- **Alloy** — DaemonSet log collector (pod logs, journal, K8s events)

## Deployment

    ./scripts/deploy-monitoring.sh

## Ingress

| Service | URL | Auth |
|---------|-----|------|
| Grafana | `https://grafana.<DOMAIN>` | Built-in login |
| Prometheus | `https://prometheus.<DOMAIN>` | Basic-auth (admin/admin) |
| Alertmanager | `https://alertmanager.<DOMAIN>` | Basic-auth (admin/admin) |

Basic-auth is a placeholder — replaced by Keycloak OIDC in Bundle 4.

## Dashboards (18)

Home, Firing Alerts, etcd, API Server, Node Detail, Traefik, CoreDNS, Cilium,
CNPG, Redis, Loki, Loki Stack, Alloy, OAuth2-proxy, Cluster Autoscaler,
Vault, cert-manager, ESO.

## Alert Groups (9)

Kubernetes, Cilium, Loki, Monitoring Self, Node, Traefik, PostgreSQL, Redis, OAuth2-proxy.

## Verify

    ./scripts/deploy-monitoring.sh --validate
