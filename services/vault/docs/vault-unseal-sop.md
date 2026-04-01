# Vault Unseal SOP

Standard operating procedure for unsealing Vault pods after restarts.

## When This Is Needed

Vault uses Shamir seal (5 shares, threshold 3). After **any** pod restart — rolling
upgrade, node drain, OOM kill, or manual deletion — the restarted pod comes up sealed
and cannot serve requests. The `VaultSealed` alert fires after 2 minutes.

Sealed pods remain in `Running` state but fail readiness probes. Services that depend
on Vault (cert-manager, ESO, application secrets) degrade until all replicas are
unsealed and the Raft cluster re-establishes quorum.

## Prerequisites

| Requirement | Details |
|-------------|---------|
| `vault-init.json` | Contains unseal keys and root token. Location: `$REPO_ROOT/vault-init.json` |
| `kubectl` access | Kubeconfig with exec permissions to the `vault` namespace |
| `jq` installed | Parses unseal keys from the init file |

Verify access before proceeding:

```bash
kubectl exec -n vault vault-0 -- vault status
```

A sealed pod returns exit code 2 and shows `Sealed: true`.

## Quick Unseal (Single Pod)

Unseal a specific pod (replace `vault-0` with the target pod):

```bash
for k in 0 1 2; do
  key=$(jq -r "(.unseal_keys_hex // .keys)[${k}]" vault-init.json)
  kubectl exec -n vault vault-0 -- vault operator unseal "$key"
done
```

The third key crosses the threshold and transitions the pod to unsealed. Confirm with:

```bash
kubectl exec -n vault vault-0 -- vault status
```

Expected output includes `Sealed: false` and a non-empty `Cluster ID`.

## Unseal All Pods

Use the deploy script's `--unseal-only` flag to unseal all 3 replicas in one command:

```bash
./scripts/deploy-pki-secrets.sh --unseal-only
```

This iterates over vault-0, vault-1, and vault-2, applying 3 unseal keys to each.
The script reads keys from `$REPO_ROOT/vault-init.json` automatically.

## Verification

Check every replica:

```bash
for i in 0 1 2; do
  echo "--- vault-${i} ---"
  kubectl exec -n vault "vault-${i}" -- vault status
done
```

Confirm for each pod:

| Field | Expected Value |
|-------|----------------|
| Sealed | `false` |
| HA Enabled | `true` |
| HA Mode | `active` (one pod) or `standby` (other two) |
| Raft Committed Index | Same across all replicas (may lag briefly) |

Verify Raft peer list from the active node:

```bash
kubectl exec -n vault vault-0 -- vault operator raft list-peers
```

All 3 nodes appear as `voter` with one `leader`.

## Automation Considerations

The current Shamir seal is intentional — it ensures no single system or credential can
unseal Vault without human intervention. This is the strongest seal posture but requires
operator action after every pod restart.

Alternatives that eliminate manual unsealing:

| Method | Trade-off |
|--------|-----------|
| **Transit auto-unseal** | Requires a second Vault cluster (circular dependency risk) |
| **AWS/GCP/Azure KMS** | Cloud dependency; suitable if cloud KMS is already in the threat model |
| **Kubernetes auth seal** | Ties unseal to K8s service account; weaker isolation |

If the operational burden of manual unsealing becomes unacceptable, document the
decision in an ADR before switching seal types. Changing seal type requires a full
Vault migration (`vault operator migrate`).

## Troubleshooting

### Pod stays sealed after 3 keys

Verify you are using the correct `vault-init.json`. Each Vault initialization generates
unique keys. If the cluster was re-initialized, the old keys are invalid.

```bash
jq '.unseal_keys_hex | length' vault-init.json
# Expected: 5
```

### Raft peer not joining after unseal

If a replica unseals but does not rejoin the Raft cluster, manually re-join it:

```bash
kubectl exec -n vault vault-1 -- vault operator raft join http://vault-0.vault-internal:8200
```

Then unseal again — Raft join resets the seal state.

### Leader election delay

After unsealing all pods, the Raft cluster may take up to 30 seconds to elect a leader.
If `HA Mode` shows `sealed` or no leader appears:

1. Confirm all 3 pods show `Sealed: false`.
2. Wait 30 seconds and re-check.
3. If still no leader, restart the pods one at a time and unseal each after restart.

### Wrong number of unseal keys applied

Vault tracks unseal progress per pod. If you accidentally apply only 1 or 2 keys, the
pod remains sealed. Run the full 3-key sequence again — duplicate keys within the same
unseal attempt are rejected, but the progress counter persists until the pod restarts or
the threshold is met.

### VaultSealed alert keeps firing

The `VaultSealed` alert has a 2-minute `for` duration. After unsealing, wait at least
2 minutes for the alert to resolve. If it persists, confirm the ServiceMonitor can
reach the metrics endpoint:

```bash
kubectl exec -n vault vault-0 -- curl -s http://localhost:8200/v1/sys/metrics?format=prometheus | head -5
```
