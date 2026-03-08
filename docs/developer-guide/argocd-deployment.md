# ArgoCD Deployment Patterns

ArgoCD handles **application deployment** -- your services, APIs, and workloads. It runs after the platform is fully bootstrapped by Fleet. For platform-level deployment, see [Fleet Deployment](fleet-deployment.md).

## How ArgoCD Fits In

The deployment boundary is clear:

- **Fleet** deploys ArgoCD itself (as bundle group `40-gitops/argocd`).
- **ArgoCD** deploys everything that lives in GitLab repos after the platform is up.
- Fleet and ArgoCD never manage the same resources.

ArgoCD is deployed in HA mode (2 controller replicas, 2+ server replicas, redis-ha with 3 replicas) and is accessible at `https://argo.aegisgroup.ch`. Authentication is via Keycloak OIDC -- the `platform-admins` and `infra-engineers` groups get admin access, while `developers` and `senior-developers` get read-only.

## ArgoCD-GitLab Connection

ArgoCD cannot connect to GitLab until GitLab is running. The `argocd-gitlab-setup` Job (deployed by Fleet in `40-gitops/argocd-manifests/manifests/argocd-gitlab-setup.yaml`) automates this bootstrap:

1. Reads the Vault root token from the `vault-init-keys` secret.
2. Reads the GitLab root password from `gitlab-gitlab-initial-root-password`.
3. Waits for the GitLab API to become ready.
4. Creates a Personal Access Token (PAT) with `read_repository`, `read_registry`, and `read_api` scopes.
5. Stores the PAT in Vault at `kv/services/argocd`.
6. Creates a `gitlab-repo-creds` Secret in the `argocd` namespace (labeled `argocd.argoproj.io/secret-type: repo-creds`) so ArgoCD can pull from any `https://gitlab.aegisgroup.ch/*` repo.
7. Patches the `default` AppProject to allow GitLab source repos and all cluster destinations.

This Job is idempotent -- if a PAT already exists in Vault, it reuses it.

## Creating ArgoCD Applications

Once the GitLab connection is established, create an `Application` resource to deploy your service:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-service
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://gitlab.aegisgroup.ch/apps/my-service.git
    targetRevision: main
    path: deploy/
    helm:
      valueFiles:
        - values-prod.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: my-service
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Key fields:

- `source.repoURL` -- must be a GitLab repo under `https://gitlab.aegisgroup.ch/`. The template credential covers all repos.
- `source.path` -- the directory containing your Helm chart or Kustomize overlay.
- `syncPolicy.automated` -- enables auto-sync. Omit this for manual sync control.
- `syncPolicy.syncOptions` -- `CreateNamespace=true` lets ArgoCD create the target namespace.

### ApplicationSets

For deploying the same service across multiple environments or namespaces, use an `ApplicationSet`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: my-service
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - env: staging
            namespace: my-service-staging
          - env: production
            namespace: my-service
  template:
    metadata:
      name: "my-service-{{env}}"
    spec:
      project: default
      source:
        repoURL: https://gitlab.aegisgroup.ch/apps/my-service.git
        targetRevision: main
        path: deploy/
        helm:
          valueFiles:
            - "values-{{env}}.yaml"
      destination:
        server: https://kubernetes.default.svc
        namespace: "{{namespace}}"
```

## Progressive Delivery with Argo Rollouts

Argo Rollouts is deployed alongside ArgoCD (Fleet bundle `40-gitops/argo-rollouts`). It replaces standard Kubernetes `Deployment` resources with `Rollout` resources that support canary and blue-green strategies.

### Canary Deployments

Gradually shift traffic to a new version while validating metrics:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: my-service
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
      app: my-service
  template:
    metadata:
      labels:
        app: my-service
    spec:
      containers:
        - name: my-service
          image: harbor.aegisgroup.ch/apps/my-service:v1.2.3
```

### ClusterAnalysisTemplates

The platform provides shared analysis templates in `fleet-gitops/40-gitops/analysis-templates/manifests/`:

- **`success-rate`** -- checks HTTP success rate against a threshold.
- **`latency-check`** -- validates response latency percentiles.
- **`error-rate`** -- fails the rollout if error rate exceeds a limit.

Reference these in your Rollout's `analysis` steps. They query the platform's Prometheus instance.

### Blue-Green Deployments

For instant switchover with a preview environment:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: my-service
spec:
  replicas: 3
  strategy:
    blueGreen:
      activeService: my-service
      previewService: my-service-preview
      autoPromotionEnabled: false
      previewReplicaCount: 3
      scaleDownDelaySeconds: 30
  selector:
    matchLabels:
      app: my-service
  template:
    metadata:
      labels:
        app: my-service
    spec:
      containers:
        - name: my-service
          image: harbor.aegisgroup.ch/apps/my-service:v1.2.3
```

This deploys the new version behind `my-service-preview`. After validation, promote manually:

```bash
kubectl argo rollouts promote my-service -n my-namespace
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

Or use the ArgoCD UI at `https://argo.aegisgroup.ch` to view sync history and roll back to a previous state.

## Troubleshooting

Check ArgoCD application sync status:

```bash
argocd app get my-service
argocd app sync my-service --dry-run
```

Check Argo Rollouts status:

```bash
kubectl argo rollouts status my-service -n my-namespace
kubectl argo rollouts get rollout my-service -n my-namespace
```

View the ArgoCD-GitLab setup Job logs if repo connectivity fails:

```bash
kubectl logs -n argocd job/argocd-gitlab-setup
```

See [CI/CD Pipeline Architecture](../architecture/cicd-pipeline.md) for the full progressive delivery design.
