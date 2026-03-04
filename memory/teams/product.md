# Product Team — harvester-rke2-svcs

## Purpose
Deploy production-grade services onto RKE2 clusters provisioned by the rke2-cluster-via-rancher project.

## Service Bundles (Planned)
| Bundle | Services | Rationale |
|--------|----------|-----------|
| PKI & Secrets | Vault, cert-manager, ESO | Tightly coupled — secrets/TLS foundation |
| (TBD) | ... | ... |

## Acceptance Criteria (Global)
- GIVEN a freshly installed RKE2 cluster WHEN a service bundle is deployed THEN all pods reach Running state within 10 minutes
- GIVEN a deployed service WHEN TLS certificate expires THEN cert-manager auto-renews without downtime
- GIVEN a deployed service WHEN a secret rotates in Vault THEN ESO syncs within 15 minutes

## DORA Targets
- Deployment Frequency: On-demand per service
- Lead Time: <1 hour from commit to deployed
- MTTR: <1 hour
- Change Failure Rate: <15%
