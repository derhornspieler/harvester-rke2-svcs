# Microservice Demo

A complete example of a service deployed on the harvester-rke2-svcs platform.

## What This Demonstrates

- Go HTTP service with Prometheus metrics
- Multi-stage Docker build
- GitLab CI/CD pipeline (build, scan, push)
- Harbor container registry integration
- Kubernetes Deployment with health checks
- ArgoCD GitOps deployment
- Argo Rollouts canary strategy
- Service metrics and monitoring

## Quick Start

### 1. Clone This Repo

```bash
git clone https://gitlab.CHANGEME_DOMAIN/your-org/microservice-demo.git
cd microservice-demo
```

### 2. Build Locally

```bash
go build -o microservice-demo main.go
./microservice-demo
# Server listening on :8080
```

Test the service:

```bash
curl http://localhost:8080/health
curl http://localhost:8080/hello
curl http://localhost:8080/metrics
```

### 3. Build Container

```bash
docker build -t microservice-demo:latest .
docker run -p 8080:8080 microservice-demo:latest
```

### 4. Deploy to Kubernetes

#### Option A: Direct Kubectl

```bash
kubectl apply -k k8s/
```

#### Option B: ArgoCD

```bash
kubectl apply -f k8s/argocd-app.yaml
# ArgoCD will sync automatically
```

## File Structure

```text
.
├── main.go                 # Service code
├── go.mod                  # Go module definition
├── Dockerfile              # Container image
├── .gitlab-ci.yml          # CI/CD pipeline
├── k8s/
│   ├── deployment.yaml     # Kubernetes Deployment
│   ├── service.yaml        # Kubernetes Service
│   ├── kustomization.yaml  # Kustomize config
│   └── argocd-app.yaml     # ArgoCD Application
├── argocd/
│   └── rollout.yaml        # Argo Rollouts config (canary strategy)
└── README.md               # This file
```

## How It Works

### Service Code

`main.go` implements a simple HTTP server with three endpoints:

- `GET /health` -- Health check (used for Kubernetes probes)
- `GET /hello` -- Returns "Hello from microservice-demo"
- `GET /metrics` -- Prometheus metrics (automatically scraped)

### CI/CD Pipeline (.gitlab-ci.yml)

1. **build:image** -- Build container with Kaniko, push to Harbor
2. **scan:image** -- Scan with Trivy for CVEs
3. **deploy:argocd** -- Deploy via ArgoCD (manual gate)

### Deployment (k8s/)

- **deployment.yaml** -- 3 replicas, health checks, anti-affinity
- **service.yaml** -- ClusterIP service on port 8080
- **kustomization.yaml** -- Kustomize orchestration
- **argocd-app.yaml** -- ArgoCD Application CRD

### Progressive Delivery (argocd/rollout.yaml)

Uses Argo Rollouts canary strategy:

1. Deploy new version
2. Shift 5% traffic, pause 5 minutes
3. Run success-rate analysis
4. Shift 50% traffic, pause 5 minutes
5. Run success-rate and error-rate analysis
6. Shift 100% traffic
7. If any health check fails, rollback automatically

## Customizing for Your Service

1. Replace `main.go` with your service code
2. Update `Dockerfile` if needed
3. Edit `k8s/deployment.yaml` for your image, ports, resources
4. Update `.gitlab-ci.yml` registry URL and image name
5. Push to GitLab and watch CI/CD run

## Monitoring

Once deployed, Prometheus scrapes `/metrics`. Access Grafana to see:

- HTTP request rate
- Request latency histogram
- Error rates

Add a Grafana dashboard by creating a ConfigMap with JSON.

## Troubleshooting

### Pod won't start (CrashLoopBackOff)

```bash
kubectl logs deployment/microservice-demo -n microservice-demo
kubectl describe pod -l app=microservice-demo -n microservice-demo
```

### Image pull fails

```bash
# Verify image exists in Harbor
# Check Harbor credentials in ImagePullSecret
kubectl get secret -n microservice-demo
kubectl describe secret harbor-pull-secret -n microservice-demo
```

### ArgoCD not syncing

```bash
# Check Application status
kubectl get application microservice-demo -n argocd -o yaml

# Check ArgoCD controller logs
kubectl logs -n argocd deployment/argocd-server
```

## Next Steps

- Modify the service code and push to GitLab
- Watch the CI/CD pipeline automatically build and deploy
- Use Argo Rollouts UI to watch the canary deployment
- Check Grafana dashboards for metrics

## Resources

- [Go HTTP Server](https://golang.org/doc/articles/wiki/)
- [Prometheus Client Library](https://github.com/prometheus/client_golang)
- [Kubernetes Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)
- [ArgoCD Applications](https://argo-cd.readthedocs.io/en/stable/user-guide/application/)
- [Argo Rollouts](https://argoproj.github.io/argo-rollouts/)
