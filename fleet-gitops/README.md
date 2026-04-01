# Fleet GitOps Baseline

OCI-first Fleet bundles for the RKE2 platform baseline.

## Bundle Ordering

| Bundle | Services | Depends On |
|--------|----------|------------|
| 00-operators | CNPG, Redis, node-labeler, storage-autoscaler, cluster-autoscaler | None |
| 05-pki-secrets | cert-manager, Vault, ESO | 00-operators |
| 10-identity | Keycloak, keycloak-config | 05-pki-secrets |
| 20-monitoring | Loki, Alloy, kube-prometheus-stack, ingress-auth | 05-pki-secrets, 10-identity |
| 30-harbor | MinIO, CNPG, Valkey, Harbor | 05-pki-secrets, 10-identity |
| 40-gitops | ArgoCD, Argo Rollouts, Argo Workflows | 05-pki-secrets, 10-identity |
| 50-gitlab | CNPG, Redis, GitLab, Runners | 05-pki-secrets, 10-identity, 30-harbor |

## Bootstrap

1. Push Helm charts: `./scripts/push-charts.sh`
2. Push Fleet bundles: `./scripts/push-bundles.sh`
3. Apply Bundle CRs to Rancher: `kubectl apply -f bundle-crs/`
4. After GitLab deploys, switch to GitRepo-based workflow.
