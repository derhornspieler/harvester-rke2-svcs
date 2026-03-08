# Fleet GitOps Deployment

Fleet is the **platform deployment** tool. It bootstraps and manages the entire platform stack -- operators, PKI, identity, monitoring, Harbor, GitOps tooling, and GitLab -- before ArgoCD is even running. Once ArgoCD is up, application teams use ArgoCD instead (see [ArgoCD Deployment](argocd-deployment.md)).

## Fleet vs ArgoCD

| Concern | Fleet | ArgoCD |
|---------|-------|--------|
| Purpose | Platform infrastructure | Application workloads |
| Source of truth | OCI charts in Harbor | Git repos in GitLab |
| Dependency ordering | Built-in `dependsOn` across bundle groups | Manual sync waves |
| Rollout strategy | Immediate apply | Canary, blue-green via Argo Rollouts |
| When it runs | Cluster bootstrap (before GitLab exists) | After platform is fully up |

Use Fleet for platform services. Use ArgoCD for your applications.

## Fleet GitOps Repo Structure

The `fleet-gitops/` directory uses numbered prefixes to enforce deployment order:

```
fleet-gitops/
  00-operators/          # CRD operators (CNPG, Redis, etc.)
  05-pki-secrets/        # Vault, cert-manager, ESO
  10-identity/           # Keycloak + CNPG database
  20-monitoring/         # Prometheus stack, Loki, Alloy, Grafana
  30-harbor/             # Harbor registry + MinIO + Valkey
  40-gitops/             # ArgoCD, Argo Rollouts, Argo Workflows
  50-gitlab/             # GitLab + runners
  scripts/               # push-bundles.sh and helpers
```

Each numbered group has a top-level `fleet.yaml` with `dependsOn` selectors to enforce ordering. For example, `40-gitops/fleet.yaml` waits for `05-pki-secrets` and `10-identity` before deploying.

### Bundle Types

There are two kinds of bundles:

**Helm chart bundles** reference an OCI chart directly in their `fleet.yaml`:

```yaml
# fleet-gitops/40-gitops/argocd/fleet.yaml
defaultNamespace: argocd
helm:
  releaseName: argocd
  chart: oci://harbor.aegisgroup.ch/helm/argo-cd
  version: "9.4.7"
  valuesFiles:
    - values.yaml
targets:
  - clusterName: rke2-prod
```

These pull upstream charts from Harbor's pull-through cache and apply local `values.yaml` overrides.

**Raw-manifest bundles** contain a `manifests/` directory with plain YAML files:

```yaml
# fleet-gitops/00-operators/cluster-autoscaler/fleet.yaml
defaultNamespace: cluster-autoscaler
targets:
  - clusterName: rke2-prod
```

```
cluster-autoscaler/
  fleet.yaml
  manifests/
    deployment.yaml
    rbac.yaml
    ...
```

Fleet applies everything in `manifests/` as raw Kubernetes resources.

## The HelmOps Pattern: OCI-First Bootstrap

The platform cannot depend on Git for bootstrap -- GitLab does not exist yet at cluster bring-up time. Instead, `push-bundles.sh` pre-packages every raw-manifest bundle as a Helm chart and pushes it to `oci://harbor.aegisgroup.ch/fleet/`.

### How push-bundles.sh Works

The script at `fleet-gitops/scripts/push-bundles.sh`:

1. Ensures the `fleet` project exists in Harbor.
2. Logs into the Helm OCI registry.
3. For each raw-manifest bundle listed in the `BUNDLES` array:
   - Creates a temporary `Chart.yaml` with the bundle's chart name and version.
   - Copies all YAML files from `manifests/` into `templates/`.
   - Runs `helm package` to produce a `.tgz`.
   - Runs `helm push` to upload to `oci://harbor.aegisgroup.ch/fleet/<chart-name>`.

Usage:

```bash
cd fleet-gitops/scripts
./push-bundles.sh                    # uses default version 1.0.0
./push-bundles.sh --version 2.1.0   # specify a version
BUNDLE_VERSION=2.1.0 ./push-bundles.sh  # or use env var
```

The `BUNDLES` array maps directory paths to chart names using `<dir-path>:<chart-name>` format. For example:

```
"00-operators/cluster-autoscaler:operators-cluster-autoscaler"
"10-identity/keycloak-config:identity-keycloak-config"
```

### Why OCI-First?

- At bootstrap, only Harvester and Harbor exist -- no Git server.
- Fleet watches Harbor OCI charts, not a Git repo.
- Once GitLab is deployed (group `50-gitlab`), ArgoCD takes over for application delivery.
- The platform can be rebuilt from a Harbor backup without needing Git at all.

## Adding a New Service Bundle

### Raw-Manifest Bundle

1. Create a directory under the appropriate numbered group:

    ```bash
    mkdir -p fleet-gitops/20-monitoring/my-exporter/manifests
    ```

2. Add your Kubernetes YAML files to `manifests/`:

    ```bash
    # Add your deployment, service, configmap, etc.
    cp my-exporter-deployment.yaml fleet-gitops/20-monitoring/my-exporter/manifests/
    ```

3. Create `fleet.yaml`:

    ```yaml
    defaultNamespace: monitoring
    targets:
      - clusterName: rke2-prod
    ```

4. Register the bundle in `push-bundles.sh` by adding an entry to the `BUNDLES` array:

    ```bash
    "20-monitoring/my-exporter:monitoring-my-exporter"
    ```

5. Run `push-bundles.sh` to package and push to Harbor.

### Helm Chart Bundle

1. Create a directory under the appropriate group:

    ```bash
    mkdir -p fleet-gitops/20-monitoring/my-chart
    ```

2. Create `fleet.yaml` referencing the OCI chart:

    ```yaml
    defaultNamespace: monitoring
    helm:
      releaseName: my-chart
      chart: oci://harbor.aegisgroup.ch/helm/my-chart
      version: "1.2.3"
      valuesFiles:
        - values.yaml
    targets:
      - clusterName: rke2-prod
    ```

3. Add a `values.yaml` with your overrides.

4. No entry in `push-bundles.sh` is needed -- Fleet pulls the chart directly from Harbor.

### Adding Dependencies

If your bundle depends on another group or bundle, add `dependsOn` to your `fleet.yaml`:

```yaml
dependsOn:
  - selector:
      matchLabels:
        fleet.cattle.io/bundle-name: 05-pki-secrets
```

## Testing Changes Locally

Before pushing to Harbor, validate your manifests:

```bash
# Lint YAML
yamllint fleet-gitops/20-monitoring/my-exporter/manifests/

# Validate against Kubernetes schemas
kubeconform -strict fleet-gitops/20-monitoring/my-exporter/manifests/

# For Helm chart bundles, template locally
helm template my-chart oci://harbor.aegisgroup.ch/helm/my-chart \
  --version 1.2.3 \
  -f fleet-gitops/20-monitoring/my-chart/values.yaml

# Dry-run push-bundles.sh by packaging without pushing
cd fleet-gitops/scripts
# Inspect the BUNDLES array to confirm your entry is correct
grep "my-exporter" push-bundles.sh
```

To test a raw-manifest bundle's packaged chart:

```bash
# Package it manually
helm package /tmp/my-chart-dir --destination /tmp/
# Inspect the contents
tar -tzf /tmp/my-chart-1.0.0.tgz
```

For full integration testing, push to Harbor and let Fleet reconcile on the cluster. Check Fleet bundle status with:

```bash
kubectl get bundles -A
kubectl describe bundle <bundle-name> -n fleet-local
```
