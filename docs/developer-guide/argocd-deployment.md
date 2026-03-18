# ArgoCD Deployment Patterns

ArgoCD handles **application deployment** for all services across dev, staging, and production environments. It runs after the platform is fully bootstrapped by Fleet. For platform-level deployment, see [Fleet Deployment](fleet-deployment.md).

## Centralized GitOps Model

All application deployments are managed through a single repository: `platform/platform-deployments`. This is the single source of truth for what is deployed where across all environments.

- **Your team repo** (e.g., `forge/svc-forge`) — builds and pushes container images
- **platform-deployments repo** — defines how those images are deployed across dev/staging/prod
- **ArgoCD** — watches `platform-deployments` and auto-syncs all applications

This centralized model eliminates configuration sprawl, clarifies ownership, and provides a consistent promotion path.

## How ArgoCD Fits In

The deployment boundary is clear:

- **Fleet** deploys ArgoCD itself (as bundle group `40-gitops/argocd`).
- **ArgoCD** watches the `platform-deployments` repository and applies all application manifests.
- **Your CI/CD pipeline** updates image tags in `platform-deployments` to trigger deployments.
- Fleet and ArgoCD never manage the same resources.

ArgoCD is deployed in HA mode (2 controller replicas, 2+ server replicas, redis-ha with 3 replicas) and is accessible at `https://argo.<DOMAIN>`. Authentication is via Keycloak OIDC -- the `platform-admins` and `infra-engineers` groups get admin access, while `developers` and `senior-developers` get read-only.

## ArgoCD-GitLab Connection

ArgoCD cannot connect to GitLab until GitLab is running. The `argocd-gitlab-setup` Job (deployed by Fleet in `40-gitops/argocd-manifests/manifests/argocd-gitlab-setup.yaml`) automates this bootstrap:

1. Bootstraps a Personal Access Token (PAT) via a one-line Rails runner command.
2. Waits for the GitLab API to become ready.
3. Uploads the SSH deploy key (public key) to `platform/platform-deployments` as a deploy key owned by the `gitlab-ci` service account (can_push=true).
4. Stores the SSH private key in Vault at `kv/services/ci/platform-deploy-key`.
5. Creates a `gitlab-repo-creds` Secret in the `argocd` namespace (labeled `argocd.argoproj.io/secret-type: repository-creds`) so ArgoCD can pull from the `platform-deployments` repo.
6. Configures ArgoCD AppProjects: `developer-dev`, `developer-staging`, `developer-apps` (production).

SSH deploy keys never expire, are scoped to a single project, and require no token rotation.

This Job is idempotent -- if credentials already exist in Vault, it reuses them.

## Environments and Namespaces

ArgoCD auto-discovers applications from the `platform-deployments` repository structure:

| Environment | Namespace Pattern | Image Tag Policy | Approval Gate |
|-------------|-------------------|------------------|---------------|
| **dev** | `dev-<app>` | `latest` allowed | None (auto-sync) |
| **staging** | `staging-<app>` | Semver required | Team lead review |
| **prod** | `app-<app>` | Semver required | Platform team approval |

## Directory Structure in platform-deployments

```
platform-deployments/
  base/
    microservice/              # Shared Deployment, Service, HPA
      deployment.yaml
      service.yaml
      hpa.yaml
      kustomization.yaml

  dev/
    forge/svc-forge/           # Dev overlay for svc-forge
      kustomization.yaml
    identity/identity-webui/
      kustomization.yaml

  staging/
    forge/svc-forge/           # Staging overlay
      kustomization.yaml
    identity/identity-webui/
      kustomization.yaml

  prod/
    forge/svc-forge/           # Production overlay
      kustomization.yaml
    identity/identity-webui/
      kustomization.yaml
```

Each overlay is a Kustomize `kustomization.yaml` that references the base and sets environment-specific values:

```yaml
# base/microservice/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - hpa.yaml
```

```yaml
# dev/forge/svc-forge/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: dev-svc-forge
bases:
  - ../../../base/microservice
images:
  - name: CHANGEME_IMAGE
    newName: harbor.dev.<DOMAIN>/forge/svc-forge
    newTag: latest
replicas:
  - name: svc-forge
    count: 1
```

## Adding a New Application

To add a new application to the platform-deployments repository:

1. **Create folder structure** (platform team may seed this):
   ```bash
   mkdir -p base/microservice
   mkdir -p dev/<team>/<app>
   mkdir -p staging/<team>/<app>
   mkdir -p prod/<team>/<app>
   ```

2. **Create Kustomize overlays** — use the base as a template:
   ```yaml
   # dev/<team>/<app>/kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: dev-<app>
   bases:
     - ../../../base/microservice
   images:
     - name: CHANGEME_IMAGE
       newName: harbor.dev.<DOMAIN>/<team>/<app>
       newTag: latest
   ```

3. **Submit an MR** to `platform-deployments` — platform team reviews and merges

4. **Update your CI/CD pipeline** — see [CI/CD Pipeline Guide](gitlab-ci.md#deploying-to-platformdeployments) for the deploy stage pattern

5. **Push to main** — ArgoCD auto-discovers the new app folder and creates Applications

## Environment Promotion Flow

Promotion follows a gated workflow from dev → staging → prod:

```
Your Repo (forge/svc-forge)
  ↓ Push image to Harbor
  ↓
Dev Deployment (Auto-Sync)
  ↓ Team updates image tag in platform-deployments/dev/<team>/<app>
  ↓ ArgoCD auto-syncs within ~3 minutes
  ↓
Staging Deployment (MR + Team Lead Review)
  ↓ Create MR updating platform-deployments/staging/<team>/<app>
  ↓ CODEOWNERS: team + tech lead approval
  ↓ After merge: ArgoCD auto-syncs to staging-<app> namespace
  ↓
Production Deployment (MR + Platform Team Approval)
  ↓ Create MR updating platform-deployments/prod/<team>/<app>
  ↓ CODEOWNERS: platform team approval
  ↓ After merge: ArgoCD auto-syncs to app-<app> namespace
```

## ArgoCD Application Auto-Discovery

ArgoCD uses the **git directory generator** to auto-discover applications from folder structure. Each overlay folder in `platform-deployments` becomes an Application.

For example, `dev/forge/svc-forge/kustomization.yaml` automatically creates an Application:

```yaml
metadata:
  name: svc-forge-dev
  namespace: argocd
spec:
  project: developer-dev
  source:
    repoURL: https://gitlab.<DOMAIN>/platform/platform-deployments.git
    targetRevision: main
    path: dev/forge/svc-forge
  destination:
    server: https://kubernetes.default.svc
    namespace: dev-svc-forge
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

No manual Application creation needed. Just add a kustomization.yaml and ArgoCD discovers it automatically.

## ArgoCD Projects for RBAC

Three AppProjects enforce access control:

- **developer-dev** — developers can sync dev namespace applications (auto-sync enabled)
- **developer-staging** — developers can sync staging namespace applications (manual sync)
- **developer-apps** — platform-admins only; production deployments require approval

These projects are automatically configured during the `argocd-gitlab-setup` job bootstrap.

## Progressive Delivery with Argo Rollouts

Argo Rollouts is deployed alongside ArgoCD (Fleet bundle `40-gitops/argo-rollouts`). It replaces standard Kubernetes `Deployment` resources with `Rollout` resources that support canary and blue-green strategies.

Define Rollout resources in the `base/microservice/deployment.yaml` (use `Rollout` instead of `Deployment`). ArgoCD automatically applies them via the `platform-deployments` overlays.

### Canary Deployments

Gradually shift traffic to a new version while validating metrics:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: svc-forge
spec:
  replicas: 5
  strategy:
    canary:
      steps:
        - setWeight: 20
        - pause: { duration: 5m }
        - analysis:
            templates:
              - templateName: success-rate
              - templateName: latency-check
        - setWeight: 50
        - pause: { duration: 5m }
        - setWeight: 80
        - pause: { duration: 5m }
  selector:
    matchLabels:
      app: svc-forge
  template:
    metadata:
      labels:
        app: svc-forge
    spec:
      containers:
        - name: svc-forge
          image: harbor.dev.<DOMAIN>/forge/svc-forge:v1.2.3
```

### Shared Analysis Templates

The platform provides shared ClusterAnalysisTemplates in `fleet-gitops/40-gitops/analysis-templates/manifests/`:

- **`success-rate`** — checks HTTP success rate against a threshold
- **`latency-check`** — validates response latency percentiles
- **`error-rate`** — fails the rollout if error rate exceeds a limit

Reference these in your Rollout's `analysis` steps. They query the platform's Prometheus instance.

### Blue-Green Deployments

For instant switchover with a preview environment:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: svc-forge
spec:
  replicas: 3
  strategy:
    blueGreen:
      activeService: svc-forge
      previewService: svc-forge-preview
      autoPromotionEnabled: false
      previewReplicaCount: 3
      scaleDownDelaySeconds: 30
  selector:
    matchLabels:
      app: svc-forge
  template:
    metadata:
      labels:
        app: svc-forge
    spec:
      containers:
        - name: svc-forge
          image: harbor.dev.<DOMAIN>/forge/svc-forge:v1.2.3
```

This deploys the new version behind `svc-forge-preview`. After validation, promote manually:

```bash
kubectl argo rollouts promote svc-forge -n dev-svc-forge
```

## Rollback Strategies

### Automatic Rollback

When an `analysis` step fails during a canary rollout, Argo Rollouts automatically aborts and rolls back to the previous stable version. No manual intervention is needed.

### Manual Rollback

To abort a rollout in progress:

```bash
kubectl argo rollouts abort my-service -n my-namespace
```

To roll back to a specific revision:

```bash
kubectl argo rollouts undo my-service -n my-namespace --to-revision=3
```

### ArgoCD Sync Rollback

For standard `Deployment` resources managed by ArgoCD (not Rollouts), use ArgoCD's history:

```bash
argocd app history my-service
argocd app rollback my-service <revision-id>
```

Or use the ArgoCD UI at `https://argo.<DOMAIN>` to view sync history and roll back to a previous state.

## Troubleshooting

### Check ArgoCD application sync status

List all auto-discovered applications:

```bash
argocd app list
```

Check sync status of a specific app:

```bash
argocd app get svc-forge-dev
argocd app sync svc-forge-dev --dry-run
```

### View ArgoCD events

If an app is stuck in "OutOfSync" or "Unknown" state:

```bash
kubectl describe app svc-forge-dev -n argocd
kubectl logs -n argocd deployment/argocd-application-controller | tail -50
```

### Check Argo Rollouts status

```bash
kubectl argo rollouts status svc-forge -n dev-svc-forge
kubectl argo rollouts get rollout svc-forge -n dev-svc-forge
```

### Verify git directory generator is discovering apps

The `ApplicationSet` resource should show the discovered applications:

```bash
kubectl get applicationset -n argocd
kubectl describe applicationset argocd-appset -n argocd
```

### Check platform-deployments repository connectivity

If ArgoCD cannot pull from `platform-deployments`:

```bash
kubectl logs -n argocd job/argocd-gitlab-setup
kubectl get secret gitlab-repo-creds -n argocd -o yaml
```

Verify the SSH deploy key in Vault is still valid:

```bash
vault kv get kv/services/ci/platform-deploy-key
```

If the key is missing, the `argocd-gitlab-setup` Job will re-upload it on next run.

### Manual sync if auto-sync stalls

```bash
argocd app sync svc-forge-dev
```

Or sync all apps:

```bash
argocd app sync --all
```

See [CI/CD Pipeline Architecture](../architecture/cicd-pipeline.md) for the full progressive delivery design and [GitLab CI/CD Guide](gitlab-ci.md) for deployment pipeline patterns.
