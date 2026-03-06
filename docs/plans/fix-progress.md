# Fix Progress Tracker — cluster-code-alignment

**Branch**: `fix/cluster-code-alignment`
**Base commit**: `09a40ca` (Harbor ESO fixes + audit plan baseline)
**Source**: `docs/plans/cluster-vs-code-audit.md` (88 items, 80 actionable)
**Airgap note**: RKE2 `registries.yaml` handles image rewrites — no YAML image changes needed
**CRDs**: Gateway API CRDs go to `scripts/manifests/`

## Agent Dispatch Plan

| Batch | Agent | Scope | Items | Status |
|-------|-------|-------|-------|--------|
| 1 | k8s-infra-engineer | VolumeAutoscalers, HPAs, PDBs, deploy script phases, CNPG fixes | A04,A05,A11,A15,A16,A17,A21,A25,A26,A27,A52,A64,A65,A66,A67,A68,A70,A71,A85 | DONE |
| 2 | security-sentinel | subst.sh guards, OAuth2-proxy securityContext, MinIO securityContext, Valkey securityContext, Workflows auth | A02,A18,A19,A35,A38,A55,A59,A60,A61,A62,A72,A74 | DONE |
| 3 | platform-developer | ArgoCD values fixes, Workflows ExternalSecret, PgBouncer deploy step, gitlab-minio-storage ES, CRDs, .env.example, cert-manager nodeSelector, vault-root-ca CMs | A12,A20,A39,A41,A43,A44,A45,A46,A47,A48,A49,A50,A73,A75,A76,A77,A82,A86,A87,A88 | DONE |
| 4 | platform-engineer | MANIFEST cleanups, traefik-dashboard script, dead code removal, deploy script cleanup | A03,A13,A22,A28,A29,A32,A42,A51,A53,A63,A84 | DONE |
| 5 | tech-doc-keeper | Documentation fixes: node count, Redis operator docs, grafana-pg, Hubble hostname, architecture diagrams | A07,A08,A09,A10,A33,A34 | DONE |

## Already Fixed (pre-branch)

| Item | Description | Fixed By |
|------|-------------|----------|
| A54 | Harbor inline secrets → existingSecret | Other Claude (committed as baseline) |
| A82 | 3 Harbor ExternalSecrets applied in deploy script | Other Claude (committed as baseline) |

## Resolved (no code change needed)

| Item | Reason |
|------|--------|
| A14 | RKE2 registries.yaml handles image rewrite |
| A24 | RKE2 registries.yaml handles image rewrite |
| A30 | RKE2 registries.yaml handles image rewrite |
| A31 | RKE2 registries.yaml handles image rewrite |
| A40 | RKE2 registries.yaml handles image rewrite |
| A80 | RKE2 registries.yaml handles image rewrite |
| A81 | RKE2 registries.yaml handles image rewrite |
| A87 | Merged into A76 |

## Agent Results

### Batch 1: k8s-infra-engineer
- Status: DONE (commit a35621c)
- Worktree: merged + cleaned
- Items completed: A04,A05,A11,A15,A16,A17,A21,A25,A26,A27,A52,A64,A65,A66,A67,A68,A70,A71,A85
- New files: 6 (cnpg-operator HPA+PDB, vault VAs, argocd PDBs, rollouts PDB, harbor PDBs)
- Modified: 8 (4 deploy scripts, argocd-values, gitlab values, gitlab VAs, harbor VAs)

### Batch 2: security-sentinel
- Status: DONE (commit e9a1f68)
- Worktree: merged + cleaned
- Items completed: A02(no-fix),A18,A19,A35(already-ok),A38,A55,A59(documented),A60,A61,A62(documented),A72(documented),A74(documented)
- Modified: 11 files (subst.sh, vault.sh, 5 securityContext YAMLs, mc job, rollouts/workflows values, vault httproute)

### Batch 3: platform-developer
- Status: DONE (commit 750a95b)
- Worktree: merged from agent-abd264f4
- Items completed: A12,A20,A39,A41,A43,A44,A45,A46,A47,A48,A49,A50,A73,A75,A76,A77,A86,A88
- New files: 4 (Gateway API CRDs in scripts/manifests/, Workflows ES, GitLab MinIO ES)
- Modified: 21 (deploy scripts, ArgoCD values, rollouts values, all gateway.yamls, .env.example, kustomization.yaml)
- Key changes:
  - ArgoCD rootCA + TLS certs inline, server.insecure param, RBAC matchMode
  - cert-manager duration/renew-before on all Gateways (720h/168h)
  - Vendored Gateway API CRDs for airgap
  - vault-root-ca ConfigMaps in harbor, keycloak, argo, gitlab namespaces
  - cert-manager sub-component nodeSelectors
  - GitLab Helm v9.9.2, Runner v0.86.0 version pins
  - PgBouncer pooler deploy step, MinIO storage ES
  - Airgap section in .env.example with HELM_REPO_CNPG

### Batch 4: platform-engineer
- Status: DONE (commit 4ba409e)
- Worktree: merged from agent-ad89421e
- Items completed: A03,A13,A22,A28,A29,A32,A42,A51,A53,A63,A84
- New files: 2 (deploy-traefik-dashboard.sh, traefik-dashboard/kustomization.yaml)
- Deleted: 1 (external-secret-redis.yaml)
- Modified: 8 (4 MANIFESTs, 2 READMEs, kube-prometheus-stack-values, deploy-argo.sh)
- Key changes:
  - MANIFESTs match cluster state (phases, resources, image tags v2.14.2)
  - Removed stale basic-auth refs from Argo MANIFEST + README
  - Grafana sessionAffinity 1800→10800s
  - Harbor README Day-2 ops section

### Batch 5: tech-doc-keeper
- Status: DONE (commits 75aaad8, 9819e04)
- Worktree: main (committed directly)
- Changes:
  - A07: Fixed node count in MEMORY.md (12→13)
  - A08: Added Redis operator install instructions to getting-started.md
  - A09: Added grafana-pg to CNPG clusters in architecture.md
  - A10: Fixed Hubble hostname in services/hubble/README.md + services/cilium/README.md
  - A33: Fixed cluster-autoscaler ServiceMonitor namespace and label selectors
  - A34: Verified Keycloak dashboard ConfigMap has correct Grafana labels

## Merge Order

1. k8s-infra-engineer (new files + deploy script phase additions)
2. security-sentinel (modify existing files — subst.sh, OAuth2-proxy YAMLs)
3. platform-developer (deploy script modifications, new files, values fixes)
4. platform-engineer (MANIFEST cleanups, new script, dead code removal)
5. tech-doc-keeper (documentation only — no conflicts expected)

## New Findings (discovered during fixes)

- ArgoCD rootCA contains hardcoded Example Org Root CA cert — environment-specific but matches cluster
- Rollouts trafficRouterPlugins commented out (requires airgap URL override in .env)

## Verification Checklist (post-merge)

- [x] All deploy scripts parse cleanly (`bash -n scripts/deploy-*.sh`)
- [ ] All YAML files are valid (`yamllint`)
- [ ] All kustomization.yaml files build (`kubectl kustomize`)
- [x] No CHANGEME tokens remain unguarded in subst.sh
- [x] Gateway API CRDs present in scripts/manifests/
- [x] .env.example has HELM_REPO_CNPG and airgap section
- [x] Node count correct in README.md and MEMORY.md
- [x] Sequential deploy order preserved (B1→B2→B3→B4→B5→B6)
