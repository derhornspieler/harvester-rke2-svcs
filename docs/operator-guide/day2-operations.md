# Day-2 Operations

Maintenance, troubleshooting, upgrades, and incident response for the platform.

## Table of Contents

- [Restarting Fleet-Managed Workloads](#restarting-fleet-managed-workloads)
- [Updating Bundle Configuration](#updating-bundle-configuration)
- [Monitoring System Health](#monitoring-system-health)
- [Certificate Management and Renewal](#certificate-management-and-renewal)
- [Vault Unsealing and Key Rotation](#vault-unsealing-and-key-rotation)
- [Database Maintenance and Backups](#database-maintenance-and-backups)
- [GitLab Runner Management](#gitlab-runner-management)
- [Upgrading Helm Chart Versions](#upgrading-helm-chart-versions)
- [Common Incidents and Resolution](#common-incidents-and-resolution)

---

## Restarting Fleet-Managed Workloads

> **CRITICAL: Never use `kubectl rollout restart` on Fleet-managed resources.**
>
> Running `kubectl rollout restart` injects a `kubectl.kubernetes.io/restartedAt`
> annotation into the pod template. Fleet detects this as drift from the desired
> state and reports the resource as **Modified**. Redeploying the bundle will NOT
> fix it because Fleet's objectset still carries the stale annotation.

### How to Check if a Resource is Fleet-Managed

Before mutating any resource with kubectl, check for Fleet ownership:

```bash
kubectl get <resource-type> <name> -n <namespace> \
  -o jsonpath='{.metadata.annotations.objectset\.rio\.cattle\.io/id}'
```

If this returns a value (e.g., `default-gitops-argocd`), the resource is
**Fleet-managed** and must only be changed through the Fleet GitOps workflow.

### Correct Restart Procedure

To restart pods for a Fleet-managed workload:

1. **Add or update a `rollme` annotation** in the pod template of your
   values file (e.g., `40-gitops/argocd/values.yaml`):

   ```yaml
   # For Helm chart values that support podAnnotations:
   controller:
     podAnnotations:
       rollme: "2026-03-11-1"  # Change this value each time you need a restart
   ```

   For raw manifests, add the annotation directly to
   `spec.template.metadata.annotations`.

2. **Bump `BUNDLE_VERSION`** in `fleet-gitops/.env`:

   ```bash
   # Increment the patch version
   # e.g., 1.0.45 -> 1.0.46
   vim fleet-gitops/.env
   ```

3. **Render, push, and deploy**:

   ```bash
   cd fleet-gitops
   scripts/render-templates.sh
   scripts/push-bundles.sh
   scripts/deploy-fleet-helmops.sh
   ```

4. **Verify** the pods restarted:

   ```bash
   kubectl get pods -n <namespace> -l <label-selector> -o wide
   ```

### Recovery: Resource Already in "Modified" State

If someone already ran `kubectl rollout restart` and Fleet shows "Modified":

1. Bump `BUNDLE_VERSION` in `.env`
2. Run the full push-and-deploy workflow above
3. Fleet will overwrite the live resource with the correct desired state,
   clearing the "Modified" status

---

## Updating Bundle Configuration

Any change to Fleet-managed resources must follow this workflow:

1. Edit the template files under `fleet-gitops/<bundle-group>/<bundle>/`
2. Bump `BUNDLE_VERSION` in `fleet-gitops/.env`
3. Render templates: `scripts/render-templates.sh`
4. (Optional) Clean up completed Jobs: `scripts/cleanup-completed-jobs.sh`
5. Push bundles: `scripts/push-bundles.sh`
6. Deploy HelmOps: `scripts/deploy-fleet-helmops.sh`

**Never** edit live resources with `kubectl edit`, `kubectl patch`,
`kubectl scale`, or `kubectl rollout restart`. All of these cause drift.

---

## Monitoring System Health

See [Monitoring & Alerts](monitoring-alerts.md) for Grafana dashboard guidance.

---

## Certificate Management and Renewal

Coming soon — cert-manager auto-renewal, Vault PKI rotation, root CA procedures.

---

## Vault Unsealing and Key Rotation

Coming soon — auto-unseal verification, key rotation schedule, break-glass procedures.

---

## Database Maintenance and Backups

Coming soon — CNPG backup verification, point-in-time recovery, failover testing.

---

## GitLab Runner Management

Coming soon — runner scaling, runner token rotation, shared vs. project runners.

---

## Upgrading Helm Chart Versions

Coming soon — chart version bumps, testing in staging, rollback procedures.

---

## Common Incidents and Resolution

| Symptom | Cause | Resolution |
|---------|-------|------------|
| Fleet bundle shows "Modified" | Manual kubectl mutation (rollout restart, scale, edit, patch) | Bump BUNDLE_VERSION and redeploy |
| Fleet bundle shows "NotReady" | Pod crashloop or pending PVC | Check pod logs and events in target namespace |
| Fleet Job conflict (immutable field) | Completed Job blocking new spec | Run `scripts/cleanup-completed-jobs.sh`, then redeploy |
| Harvester LB "ensured load balancer" noise | Harvester cloud provider conflicts with Cilium L2 | Cosmetic only — Cilium manages IPs correctly, safe to ignore |

---

[Back to Operator's Guide](index.md)
