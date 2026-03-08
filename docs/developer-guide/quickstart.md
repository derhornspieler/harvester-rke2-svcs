# Developer Quickstart

Create and deploy your first service on the platform in 10 minutes.

## What You Will Build

By the end of this guide you will have a running HTTP service that:

- Responds to requests on `/health` and `/hello`
- Exports Prometheus metrics on `/metrics`
- Runs in Kubernetes with liveness and readiness probes
- Deploys via ArgoCD with a single Git commit

No prior Kubernetes experience is required -- just follow the steps.

## Prerequisites

Before you start, make sure you have:

| Tool | Minimum Version | Purpose |
|------|-----------------|---------|
| `git` | 2.x | Clone the repository |
| `kubectl` | 1.28+ | Interact with the cluster |
| `kustomize` | 5.x | Render Kubernetes manifests |
| `docker` or `podman` | 24+ / 4+ | Build container images |

You also need:

- **Cluster access** -- a valid kubeconfig pointed at the RKE2 cluster
- **GitLab account** -- access to the GitLab instance at `gitlab.<DOMAIN>`
- **Harbor credentials** -- push access to the container registry at `harbor.<DOMAIN>`

Ask your platform operator if you do not have these yet.

## Step 1: Clone the Example Repository

```bash
git clone https://gitlab.<DOMAIN>/platform/harvester-rke2-svcs.git
cd harvester-rke2-svcs/examples/microservice-demo
```

The `microservice-demo` directory contains everything you need:

```text
microservice-demo/
  main.go                 # Application source
  Dockerfile              # Multi-stage container build
  k8s/
    kustomization.yaml    # Kustomize entrypoint
    namespace.yaml        # Dedicated namespace
    deployment.yaml       # Deployment with probes
    service.yaml          # ClusterIP service
    httproute.yaml        # Gateway API routing
    service-monitor.yaml  # Prometheus scrape config
    argocd-app.yaml       # ArgoCD Application CR
```

## Step 2: Review the Service Code

Open `main.go`. It is a minimal HTTP server with three endpoints:

```go
func healthHandler(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
    w.Write([]byte("OK"))
}

func helloHandler(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
    w.Write([]byte("Hello from microservice-demo"))
}
```

The third endpoint, `/metrics`, is registered automatically by the Prometheus
client library. Every service on the platform should expose metrics -- this is
how Grafana dashboards and alerts work.

Key things to notice:

- **Health endpoint** -- Kubernetes uses `/health` for both liveness and
  readiness probes. If this endpoint stops responding, the pod gets restarted.
- **Metrics endpoint** -- Prometheus scrapes `/metrics` every 30 seconds. You
  get request counts, latencies, and Go runtime stats for free.
- **No framework** -- The standard library `net/http` is all you need. Add a
  router like `chi` or `gorilla/mux` when your service grows.

## Step 3: Build the Container

```bash
# Using Docker
docker build -t microservice-demo:v1.0 .

# Or using Podman (rootless, no daemon)
podman build -t microservice-demo:v1.0 .
```

Tag and push to Harbor so the cluster can pull it:

```bash
# Tag for the Harbor registry
docker tag microservice-demo:v1.0 harbor.<DOMAIN>/library/microservice-demo:v1.0

# Log in to Harbor
docker login harbor.<DOMAIN>

# Push
docker push harbor.<DOMAIN>/library/microservice-demo:v1.0
```

Replace `<DOMAIN>` with your actual domain (e.g., `dev.example.com`).

## Step 4: Configure for Your Environment

Edit `k8s/deployment.yaml` and update the image reference:

```yaml
containers:
  - name: microservice-demo
    image: harbor.<DOMAIN>/library/microservice-demo:v1.0
```

If your service needs an HTTPRoute for external access, edit
`k8s/httproute.yaml` and set the hostname:

```yaml
hostnames:
  - "demo.<DOMAIN>"
```

That is it -- Kustomize handles the rest.

## Step 5: Deploy with Kustomize

Preview what will be applied:

```bash
kustomize build k8s/
```

Review the output, then deploy:

```bash
kubectl apply -k k8s/
```

Watch the rollout:

```bash
kubectl get pods -n microservice-demo -w
```

You should see output similar to:

```text
NAME                                READY   STATUS    RESTARTS   AGE
microservice-demo-7f8b9c6d4-x2k9p  1/1     Running   0          15s
```

Check the service is registered:

```bash
kubectl get svc -n microservice-demo
```

## Step 6: Access and Test Your Service

Port-forward for local testing:

```bash
kubectl port-forward svc/microservice-demo 8080:8080 -n microservice-demo
```

In a second terminal, verify each endpoint:

```bash
# Hello endpoint
curl http://localhost:8080/hello
# Expected: Hello from microservice-demo

# Health check
curl http://localhost:8080/health
# Expected: OK

# Prometheus metrics
curl -s http://localhost:8080/metrics | head -20
# Expected: Lines starting with # HELP and # TYPE
```

If all three return the expected output, your service is running correctly.

## Step 7: Deploy via ArgoCD

Once you are satisfied with the manual deployment, switch to GitOps. ArgoCD
watches your Git repository and automatically syncs changes to the cluster.

Apply the ArgoCD Application manifest:

```bash
kubectl apply -f k8s/argocd-app.yaml
```

The Application CR tells ArgoCD:

- **Source** -- which Git repo and path to watch
- **Destination** -- which cluster and namespace to deploy to
- **Sync policy** -- whether to auto-sync or require manual approval

Open the ArgoCD UI to watch the sync:

```text
https://argo.<DOMAIN>
```

Log in with your Keycloak SSO credentials. You should see your application
appear in the dashboard with a green "Synced" status.

From now on, every `git push` to your repository triggers ArgoCD to reconcile
the cluster state. Edit a manifest, commit, push -- ArgoCD applies the change
within seconds.

## What You Just Did

1. Built a container image and pushed it to Harbor
2. Deployed a Kubernetes workload with health checks and metrics
3. Verified the service responds correctly
4. Connected the service to ArgoCD for continuous deployment

This is the foundation for every service on the platform.

## What's Next

Now that your first service is running, go deeper:

- **[Application Design](application-design.md)** -- Structure your app with
  proper health checks, configuration, and resource requests
- **[GitLab CI Patterns](gitlab-ci.md)** -- Automate builds, tests, security
  scans, and image pushes in CI/CD pipelines
- **[ArgoCD Deployment](argocd-deployment.md)** -- Set up canary deployments,
  blue-green rollouts, and automated rollbacks
- **[Platform Integration](platform-integration.md)** -- Integrate with
  Keycloak for authentication, Vault for secrets, and Loki for logging
- **[Example Repositories](getting-started-with-examples.md)** -- Explore the
  full microservice-demo and library-demo for production-ready patterns

## Resources

- [Full microservice-demo README](../../examples/microservice-demo/README.md)
- [ArgoCD Application CRD Reference](https://argo-cd.readthedocs.io/en/stable/user-guide/application-specification/)
- [Kubernetes Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)
- [Prometheus Client Libraries](https://prometheus.io/docs/instrumenting/clientlibs/)
- [Kustomize Documentation](https://kubectl.docs.kubernetes.io/references/kustomize/)
