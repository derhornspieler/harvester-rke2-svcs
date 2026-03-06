# Cilium & Hubble Observability

Cilium is the default network CNI on RKE2 clusters. This directory configures Hubble observability for Cilium, providing network flow visibility, metrics, and alerts across the cluster.

## Architecture

### Hubble Components

Hubble extends Cilium's observability capabilities:

- **Cilium Agent**: Runs on each node (managed by RKE2), captures L4/L7 network events
- **Hubble Relay**: Centralized aggregator (2 replicas, `kube-system` namespace), exposes metrics via ServiceMonitor for Prometheus
- **Hubble UI**: Web dashboard (1 replica, `kube-system` namespace) protected by OAuth2-proxy for user authentication
- **Flow Export**: JSON flow logs written to `/var/run/cilium/hubble/events.log` on each node for Alloy log collection

### Observability Pipeline

```
Cilium Agent (each node)
    ↓
    [Events: L4/L7 traffic, DNS, drops, TCP flags]
    ↓
Hubble Relay (kube-system, 2 replicas)
    ├→ Prometheus ServiceMonitor (metrics)
    └→ Flow logs to /var/run/cilium/hubble/events.log
        ↓
    Alloy DaemonSet (monitoring namespace)
        ├→ Parse JSON flow logs
        ├→ Extract labels: verdict, namespaces, traffic_direction
        └→ Ship to Loki (source=hubble)

Hubble UI (kube-system, 1 replica)
    ↓ OAuth2-proxy ForwardAuth (keycloak)
    ↓
User access: https://hubble.dev.example.com
```

## Configuration

### HelmChartConfig (services/cilium/helmchartconfig.yaml)

RKE2 Cilium is configured via HelmChartConfig applied to the system chart:

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-cilium
  namespace: kube-system
spec:
  valuesContent: |-
    hubble:
      enabled: true
      metrics:
        enabled:
          - dns             # DNS query/response tracking
          - drop            # Packet drop events
          - tcp             # TCP connection state
          - flow            # Generic L3/L4 flows
          - icmp            # ICMP messages
          - httpV2          # L7 HTTP request/response (exemplars + context labels)
        serviceMonitor:
          enabled: false    # Relay has its own ServiceMonitor in monitoring-stack
      export:
        static:
          enabled: true
          content:
            flowLogs:
              - filePath: "/var/run/cilium/hubble/events.log"
                fieldMask:
                  - time
                  - source
                  - destination
                  - verdict
                  - drop_reason
                  - ethernet
                  - IP
                  - l4
                  - l7
                  - Type
                end: true
      relay:
        enabled: true
        replicas: 2
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
      ui:
        enabled: true
        replicas: 1
        resources:
          requests:
            cpu: 25m
            memory: 32Mi
```

**Key settings:**

- **Metrics**: All critical event types enabled. `httpV2` with exemplars for request tracing and context labels for workload identity
- **Flow export**: Writes JSON to `/var/run/cilium/hubble/events.log` with essential fields for flow analysis
- **Relay replicas**: 2 for HA, running `kube-system` namespace (part of RKE2 system components)
- **UI replicas**: 1 stateless pod; no persistence needed
- **Resource requests**: Minimal — Hubble components are lightweight; no limits to allow bursting

## Monitoring & Dashboards

### ServiceMonitor

- **File**: `services/monitoring-stack/service-monitors/hubble-relay.yaml`
- **Target**: Hubble relay in `kube-system` namespace, port `metrics`
- **Scrape interval**: 30s (inherited from kube-prometheus-stack defaults)

### PrometheusRules (Alerts)

**File**: `services/monitoring-stack/prometheus-rules/cilium-alerts.yaml`

Five new alert groups for network health:

| Alert | Condition | Severity |
|-------|-----------|----------|
| **CiliumHighDropRate** | `sum(rate(cilium_drop_count_total[5m])) > 10` packets/sec | warning |
| **HubbleDNSErrorSpike** | `sum(rate(hubble_dns_responses_total{rcode!="No Error"}[5m])) > 5` errors/sec | warning |
| **HubbleHTTPServerErrors** | `sum(rate(hubble_http_responses_total{status=~"5.."}[5m])) > 1` responses/sec | warning |
| **HubbleLostEvents** | `sum(rate(hubble_lost_events_total[5m])) > 0` lost events/sec for 10m | warning |
| **CiliumPolicyImportErrors** | `sum(rate(cilium_policy_import_errors_total[5m])) > 0` errors/sec | **critical** |

Plus existing Cilium alerts (CiliumAgentDown, CiliumEndpointNotReady).

### Grafana Dashboard

**File**: `services/monitoring-stack/grafana/dashboards/configmap-dashboard-cilium.yaml`

Cilium overview dashboard with 9 panels:

- **Stats**: Agents up/down, endpoints (total/ready/not-ready), policy changes/sec, drops/sec
- **Trends**: Endpoint state by node, drops by namespace, policy error rate
- **Flows**: Inbound/outbound flows, verdict distribution
- **DNS**: Query rates, error spike detection, response latency
- **HTTP**: Request rates, response latencies, 5xx error rates
- **Health**: Lost events, relay lag, endpoint reconciliation

## Access & Deployment

### Ingress

- **Hostname**: `hubble.dev.example.com` (matches domain placeholder `CHANGEME_DOMAIN`)
- **Files**:
  - `services/hubble/gateway.yaml` — Cilium Gateway (listens 443, TLS from cert-manager)
  - `services/hubble/httproute.yaml` — HTTPRoute with OAuth2-proxy ForwardAuth middleware
- **Auth**: OAuth2-proxy in `keycloak` namespace validates session before proxying to UI
- **TLS**: Issued by cert-manager from Vault intermediate CA

### Deployment

Hubble is configured as part of Bundle 3 (Monitoring) deployment:

1. HelmChartConfig applied to RKE2 system chart (Cilium already running on every node)
2. ServiceMonitor created for relay metrics
3. PrometheusRules created for alerts
4. Grafana dashboard created as ConfigMap
5. Alloy DaemonSet mounts `/var/run/cilium/hubble/` for flow log collection
6. OAuth2-proxy deployed for Hubble UI authentication
7. Gateway + HTTPRoute configured for external access

## Troubleshooting

### Hubble Relay Not Reporting Metrics

**Symptom**: ServiceMonitor scrape shows 0 targets or "no data"

**Check:**

```bash
# Verify relay pods are running
kubectl -n kube-system get pods -l k8s-app=hubble-relay

# Verify metrics endpoint is exposing
kubectl -n kube-system port-forward svc/hubble-relay 4245:4245
curl http://localhost:4245/metrics | head

# Check ServiceMonitor selector matches relay labels
kubectl -n monitoring get servicemonitor hubble-relay -o yaml
```

**Common causes:**

- Relay pods not scheduled (resource requests too high)
- ServiceMonitor selector mismatch — verify `k8s-app=hubble-relay` labels exist on relay pods
- Prometheus not scraping — check Prometheus targets UI (`https://prometheus.dev.example.com/targets`)

### Hubble UI Not Accessible

**Symptom**: `https://hubble.dev.example.com` returns 401/403 or blank page

**Check:**

```bash
# Verify OAuth2-proxy is running
kubectl -n keycloak get pods -l app=oauth2-proxy-hubble

# Verify Hubble UI pod is running
kubectl -n kube-system get pods -l k8s-app=hubble-ui

# Check HTTPRoute configuration
kubectl -n kube-system get httproute hubble -o yaml

# Test OAuth2-proxy directly
kubectl -n keycloak port-forward svc/oauth2-proxy-hubble 4180:4180
curl http://localhost:4180/oauth2/auth
```

**Common causes:**

- OAuth2-proxy pod not running — check logs for credential sync issues (ESO)
- HTTPRoute not bound to Gateway — verify `parentRefs.name: hubble`
- Keycloak Hubble client not configured — check `scripts/setup-keycloak.sh` output

### Flow Logs Not Appearing in Loki

**Symptom**: Hubble queries in Grafana return "no data"

**Check:**

```bash
# Verify /var/run/cilium/hubble/events.log exists on nodes
ssh <node> ls -la /var/run/cilium/hubble/

# Verify Alloy is reading the file
kubectl -n monitoring logs -l app=alloy | grep hubble

# Check Alloy config has correct file path
kubectl -n monitoring get cm alloy-config -o jsonpath='{.data.config\.alloy}' | grep -A 5 "hubble_flows"

# Query Loki directly for hubble source
curl -G "http://loki.monitoring.svc:3100/loki/api/v1/query" --data-urlencode 'query={source="hubble"}' | jq .
```

**Common causes:**

- Flow export disabled in HelmChartConfig — verify `hubble.export.static.enabled: true`
- Alloy DaemonSet not mounted `/var/run/cilium/hubble/` — check volumeMounts and hostPath
- Loki unreachable from Alloy — check NetworkPolicy allows `monitoring → monitoring:3100`

## Related Services

- **Prometheus** (`services/monitoring-stack/`) — Scrapes Hubble relay metrics
- **Grafana** (`services/monitoring-stack/`) — Visualizes Cilium/Hubble dashboards
- **Alertmanager** (`services/monitoring-stack/`) — Routes Cilium policy/health alerts
- **Loki** (`services/monitoring-stack/`) — Stores Hubble flow logs
- **Alloy** (`services/monitoring-stack/`) — Collects flow logs from each node
- **OAuth2-proxy** (`services/keycloak/oauth2-proxy/hubble.yaml`) — Authenticates Hubble UI access
- **Keycloak** (`services/keycloak/`) — OIDC provider for OAuth2-proxy

## See Also

- **Network Policies**: `services/monitoring-stack/networkpolicy.yaml` — Must allow `monitoring → kube-system:4244` for relay metrics
- **Alloy Pipeline**: `services/monitoring-stack/alloy/configmap.yaml` — Processes Hubble flow logs (stage.json, stage.labels)
- **Architecture Diagram**: `docs/architecture.md` — Full observability stack diagram (Bundle 3)
