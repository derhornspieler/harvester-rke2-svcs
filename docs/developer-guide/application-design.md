# Application Design Patterns

How to structure, configure, and deploy applications on the Harvester RKE2
platform. Every section includes a working Kubernetes manifest you can adapt.

Replace `<TEAM>`, `<APP>`, and `<DOMAIN>` with your actual values throughout.

---

## 1. Service Architecture

Design services as **stateless** processes. Store all state in external
backends (PostgreSQL via CNPG, Valkey, MinIO). This lets the platform scale,
restart, and reschedule pods freely.

### Replicas and HPA

Run at least 2 replicas. Attach an HPA targeting 70% average CPU utilization:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: <APP>
  namespace: <TEAM>
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: <APP>
  minReplicas: 2
  maxReplicas: 8
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

### Health Probes

Define all three probe types. Use `startupProbe` to handle slow-starting
containers without shortening liveness intervals:

```yaml
startupProbe:
  httpGet:
    path: /healthz
    port: http
  failureThreshold: 30
  periodSeconds: 2
readinessProbe:
  httpGet:
    path: /readyz
    port: http
  periodSeconds: 5
  failureThreshold: 3
livenessProbe:
  httpGet:
    path: /healthz
    port: http
  periodSeconds: 10
  failureThreshold: 3
```

### Graceful Shutdown

Set `terminationGracePeriodSeconds` to match your drain time. Handle `SIGTERM`
in your application to finish in-flight requests before exiting:

```yaml
spec:
  terminationGracePeriodSeconds: 30
  containers:
    - name: <APP>
      lifecycle:
        preStop:
          exec:
            command: ["sh", "-c", "sleep 5"]
```

The 5-second `preStop` sleep gives the endpoints controller time to remove the
pod from service before the application begins shutting down.

### Pod Anti-Affinity

Spread replicas across nodes to survive single-node failures:

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: <APP>
          topologyKey: kubernetes.io/hostname
```

### Node Selectors

Place workloads on the correct node pool:

```yaml
# Stateless services
nodeSelector:
  workload-type: general

# Stateful services (databases, caches)
nodeSelector:
  workload-type: database
```

---

## 2. Container Best Practices

### Security Context

Every pod must run as non-root with a read-only root filesystem:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
containers:
  - name: <APP>
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
```

If the application needs to write temporary files, mount an `emptyDir`:

```yaml
volumeMounts:
  - name: tmp
    mountPath: /tmp
volumes:
  - name: tmp
    emptyDir:
      sizeLimit: 64Mi
```

### Image References

All images must be pulled through the Harbor pull-through cache. Never use
`:latest` tags — pin to a specific semver or digest:

```yaml
# Correct — pulled through Harbor proxy-cache, pinned version
image: harbor.example.com/docker-hub/library/nginx:1.27.4

# Wrong — direct pull, latest tag
image: nginx:latest
```

To push your own images, use the in-cluster Harbor registry:

```
harbor.dev.<DOMAIN>/<TEAM>/<APP>:<TAG>
```

---

## 3. Configuration

### Environment Variables and ConfigMaps

Use ConfigMaps for non-sensitive configuration:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: <APP>-config
  namespace: <TEAM>
data:
  LOG_LEVEL: "info"
  DB_HOST: "<APP>-pg-rw.<TEAM>.svc.cluster.local"
  DB_PORT: "5432"
```

Reference in the deployment:

```yaml
envFrom:
  - configMapRef:
      name: <APP>-config
```

### Secrets via ESO + Vault

Never create raw Kubernetes Secrets. Store sensitive values in Vault under
`kv/services/<TEAM>/<APP>` and sync them with an ExternalSecret:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: <APP>-secrets
  namespace: <TEAM>
spec:
  refreshInterval: 5m
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: <APP>-secrets
    creationPolicy: Owner
  data:
    - secretKey: DATABASE_PASSWORD
      remoteRef:
        key: kv/services/<TEAM>/<APP>
        property: db-password
    - secretKey: API_KEY
      remoteRef:
        key: kv/services/<TEAM>/<APP>
        property: api-key
```

Reference in the deployment:

```yaml
envFrom:
  - secretRef:
      name: <APP>-secrets
```

The ESO operator syncs every 5 minutes. Use `5m` (not `1h`) so recovery from
transient Vault failures is fast — ESO caches failures with exponential
backoff.

---

## 4. Networking

### Gateway API HTTPRoute

The platform uses Gateway API with Traefik. Define an HTTPRoute (not a legacy
Ingress resource) to expose your service:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <APP>
  namespace: <TEAM>
spec:
  parentRefs:
    - name: traefik
      namespace: traefik
      sectionName: websecure
  hostnames:
    - "<APP>.<DOMAIN>"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: <APP>
          port: 8080
```

### TLS with vault-issuer

Request a TLS certificate from the platform CA using cert-manager:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: <APP>-tls
  namespace: <TEAM>
spec:
  secretName: <APP>-tls
  issuerRef:
    name: vault-issuer
    kind: ClusterIssuer
  dnsNames:
    - "<APP>.<DOMAIN>"
  duration: 2160h    # 90 days
  renewBefore: 360h  # 15 days
```

### Service Discovery

Within the cluster, reach services using their DNS name:

```
<SERVICE>.<NAMESPACE>.svc.cluster.local
```

For example, a CNPG PostgreSQL read-write endpoint:

```
<APP>-pg-rw.<TEAM>.svc.cluster.local:5432
```

---

## 5. Resource Requests

Set **requests only** — do not set limits. This is a deliberate platform
decision:

```yaml
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  # No limits — intentional
```

**Why no limits:**

- **CPU limits** cause throttling even when the node has spare capacity,
  increasing latency for no benefit.
- **Memory limits** trigger OOM kills the moment a container exceeds its limit,
  even if the node has gigabytes of free memory.
- **Requests** guarantee the scheduler reserves capacity. Omitting limits lets
  pods burst into unused node resources when needed.

The HPA scales pods based on request utilization, so set requests to reflect
your expected steady-state consumption.

---

## 6. Storage

### PersistentVolumeClaims

Use the default Harvester storage class for persistent storage:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <APP>-data
  namespace: <TEAM>
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
```

### VolumeAutoscaler

Attach a VolumeAutoscaler CR to every PVC that may grow. The autoscaler
expands the volume when usage crosses the threshold:

```yaml
apiVersion: storage.infra.cattle.io/v1alpha1
kind: VolumeAutoscaler
metadata:
  name: <APP>-data
  namespace: <TEAM>
spec:
  pvcName: <APP>-data
  threshold: 80         # Trigger expansion at 80% usage
  increasePercent: 25   # Grow by 25% each time
  maxSize: 100Gi        # Upper bound
```

Without this CR, a full PVC causes application crashes. Always define a
VolumeAutoscaler for any PVC that holds growing data (logs, uploads, database
files).

---

## Putting It All Together

A minimal production-ready Deployment combining all patterns above:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <APP>
  namespace: <TEAM>
  labels:
    app.kubernetes.io/name: <APP>
    app.kubernetes.io/part-of: <TEAM>
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: <APP>
  template:
    metadata:
      labels:
        app.kubernetes.io/name: <APP>
    spec:
      nodeSelector:
        workload-type: general
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app.kubernetes.io/name: <APP>
                topologyKey: kubernetes.io/hostname
      terminationGracePeriodSeconds: 30
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
        - name: <APP>
          image: harbor.dev.<DOMAIN>/<TEAM>/<APP>:1.0.0
          ports:
            - name: http
              containerPort: 8080
          envFrom:
            - configMapRef:
                name: <APP>-config
            - secretRef:
                name: <APP>-secrets
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            failureThreshold: 30
            periodSeconds: 2
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
          lifecycle:
            preStop:
              exec:
                command: ["sh", "-c", "sleep 5"]
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 64Mi
```

See [Application Design Examples](getting-started-with-examples.md) for
end-to-end walkthroughs including CI pipelines and ArgoCD rollouts.
