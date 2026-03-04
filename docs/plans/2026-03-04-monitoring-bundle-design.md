# Monitoring Bundle Design

**Date:** 2026-03-04
**Status:** Approved
**Bundle:** 2 of 6

## Overview

Deploy a full observability stack onto the RKE2 cluster: metrics (Prometheus), dashboards (Grafana), logs (Loki), and log collection (Alloy).

## Services

| Service | Mode | Purpose |
|---------|------|---------|
| kube-prometheus-stack | Helm chart | Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics |
| Loki | SimpleScalable (read/write separation) | Log aggregation, 7-day retention |
| Alloy | DaemonSet | Per-node log collection (pods, journal, K8s events) |

## Architecture

```
Alloy (DaemonSet, every node)
  → collects pod logs, journal, K8s events
  → ships to Loki

Prometheus (StatefulSet)
  → scrapes metrics from all services via ServiceMonitors + scrape configs
  → evaluates PrometheusRules for alerting
  → 30-day retention, 50Gi PVC

Alertmanager (StatefulSet)
  → receives alerts from Prometheus
  → routes to notification channels

Loki (SimpleScalable: read + write replicas)
  → receives logs from Alloy
  → 7-day retention, filesystem PVCs

Grafana (Deployment, HPA 2-4)
  → queries Prometheus (metrics) + Loki (logs) + Alertmanager (alerts)
  → 18 platform dashboards via ConfigMap sidecar
  → Native OIDC auth (Bundle 4 adds Keycloak integration)
```

## Directory Structure

```
services/monitoring-stack/
├── kustomization.yaml
├── namespace.yaml
├── MANIFEST.yaml
├── README.md
├── helm/
│   ├── kube-prometheus-stack-values.yaml
│   └── additional-scrape-configs.yaml
├── loki/
│   ├── configmap.yaml
│   ├── statefulset.yaml
│   ├── rbac.yaml
│   └── service.yaml
├── alloy/
│   ├── configmap.yaml
│   ├── daemonset.yaml
│   ├── rbac.yaml
│   └── service.yaml
├── prometheus/
│   ├── gateway.yaml
│   ├── httproute.yaml
│   └── basic-auth-middleware.yaml
├── alertmanager/
│   ├── gateway.yaml
│   ├── httproute.yaml
│   └── basic-auth-middleware.yaml
├── grafana/
│   ├── gateway.yaml
│   ├── httproute.yaml
│   └── dashboards/ (15 ConfigMaps)
├── prometheus-rules/ (9 alert groups)
└── service-monitors/ (6 monitors)
```

## Deploy Script (scripts/deploy-monitoring.sh)

| Phase | Component | What Happens |
|-------|-----------|--------------|
| 1 | Namespace + Loki + Alloy | Kustomize apply (namespace, Loki StatefulSet, Alloy DaemonSet) |
| 2 | Scrape configs | Create additional-scrape-configs Secret |
| 3 | kube-prometheus-stack | Helm install (Prometheus, Grafana, Alertmanager, Operator) |
| 4 | Rules + Monitors | Kustomize apply (9 PrometheusRules, 6 ServiceMonitors) |
| 5 | Ingress | Kustomize apply (Gateways, HTTPRoutes, basic-auth middleware) |
| 6 | Verify | Check deployments up, TLS certs issued, datasources connected |

## Ingress & Auth

| Service | URL | Auth (Bundle 2) | Auth (After Bundle 4) |
|---------|-----|-----------------|----------------------|
| Grafana | `https://grafana.CHANGEME_DOMAIN` | Built-in login (admin) | Keycloak OIDC (native) |
| Prometheus | `https://prometheus.CHANGEME_DOMAIN` | Traefik basic-auth (admin/admin) | Keycloak via OAuth2-proxy |
| Alertmanager | `https://alertmanager.CHANGEME_DOMAIN` | Traefik basic-auth (admin/admin) | Keycloak via OAuth2-proxy |

## Dashboards (18 total in Bundle 2)

**15 platform dashboards (monitoring-stack/grafana/dashboards/):**
- Home overview, firing alerts
- etcd, API server, node detail
- Traefik, CoreDNS, Cilium
- CNPG, Redis
- Loki, Loki stack, Alloy
- OAuth2-proxy, cluster autoscaler

**3 from Bundle 1 (already deployed):**
- Vault, cert-manager, ESO

## Resource Conventions

- **Requests only, no limits** — all components
- **HPA:** Grafana (2-4 replicas)
- **Storage autoscaler:** Prometheus PVC (50Gi), Loki PVCs
- **Anti-affinity:** Loki read/write replicas spread across nodes
- **Node selectors:** Loki/Prometheus on `workload-type: database`, Grafana on `workload-type: general`

## Loki SimpleScalable Configuration

| Parameter | Value |
|-----------|-------|
| Mode | SimpleScalable (read + write separation) |
| Read replicas | 2 |
| Write replicas | 2 |
| Schema | v13 (TSDB) |
| Index period | 24h |
| Retention | 7 days (compactor auto-purge) |
| Ingestion rate | 20 MB/s (burst 40) |
| Max streams | 50,000 per user |
| Storage | Filesystem PVCs |
| Auth | Disabled (cluster-internal only) |

## Alert Groups (9 PrometheusRules)

| Rule File | Categories |
|-----------|-----------|
| kubernetes-alerts | KubeAPIServerDown, EtcdMemberDown, PodCrashLooping |
| cilium-alerts | Agent connectivity, policy violations |
| loki-alerts | Ingestion errors, throughput |
| monitoring-self-alerts | PrometheusDown, AlertmanagerDown |
| node-alerts | High CPU/memory/disk, OOM kills |
| traefik-alerts | Error rate, latency, TLS expiry |
| postgresql-alerts | Connection pool, replication lag |
| redis-alerts | Memory usage, evictions |
| oauth2-proxy-alerts | Auth failures (placeholder until Bundle 4) |

## Dependencies

- Bundle 1 (PKI & Secrets): TLS certificates, Vault secrets for Grafana admin password
- Prometheus CRDs: Installed by kube-prometheus-stack Helm chart
- Gateway API CRDs: Must exist on cluster (installed by RKE2/Traefik)
