# GitOps & Workflows Bundle Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy ArgoCD (HA), Argo Rollouts (HA + dashboard), and Argo Workflows as the GitOps platform with Prometheus-driven AnalysisTemplates.

**Architecture:** Three Helm charts in separate namespaces. ArgoCD with native Keycloak OIDC. Rollouts and Workflows dashboards behind basic-auth (Gateway API + Traefik). AnalysisTemplates query Prometheus for blue/green promotion.

**Tech Stack:** ArgoCD Helm, Argo Rollouts Helm, Argo Workflows Helm, Gateway API v1, Kustomize.

**Source reference:** `../rke2-cluster-via-rancher/services/argo/`

**Agents:** platform-developer for implementation, tech-doc-keeper for docs, security-sentinel for scrub.

---

## Task 1: ArgoCD Namespace + Gateway + Helm Values

**Files:**
- Create: `services/argo/argocd/namespace.yaml`
- Create: `services/argo/argocd/argocd-values.yaml`
- Create: `services/argo/argocd/gateway.yaml`
- Create: `services/argo/argocd/httproute.yaml`

Copy from source, remove all limits from Helm values, keep CHANGEME placeholders.
ArgoCD OIDC config in values pointing to Keycloak (commented out initially with "Enabled after Keycloak argocd client is created" note, or active if Keycloak is already running).

Commit: `feat: add ArgoCD namespace, Helm values, gateway, and httproute`

---

## Task 2: Argo Rollouts Namespace + Gateway + Helm Values + Basic-Auth

**Files:**
- Create: `services/argo/argo-rollouts/namespace.yaml`
- Create: `services/argo/argo-rollouts/argo-rollouts-values.yaml`
- Create: `services/argo/argo-rollouts/gateway.yaml`
- Create: `services/argo/argo-rollouts/httproute.yaml`
- Create: `services/argo/argo-rollouts/basic-auth-middleware.yaml`

Copy gateway/httproute from source. Simplify httproute to use basic-auth middleware (not oauth2-proxy). Include basic-auth Traefik Middleware CRD.

Also copy oauth2-proxy manifests for future activation:
- `services/argo/argo-rollouts/oauth2-proxy.yaml`
- `services/argo/argo-rollouts/middleware-oauth2-proxy.yaml`
- `services/argo/argo-rollouts/external-secret-oauth2-proxy.yaml`
- `services/argo/argo-rollouts/external-secret-redis.yaml`

Remove limits from all manifests.

Commit: `feat: add Argo Rollouts namespace, Helm values, gateway with basic-auth`

---

## Task 3: Argo Workflows Namespace + Gateway + Helm Values + Basic-Auth

**Files:**
- Create: `services/argo/argo-workflows/namespace.yaml`
- Create: `services/argo/argo-workflows/argo-workflows-values.yaml`
- Create: `services/argo/argo-workflows/gateway.yaml`
- Create: `services/argo/argo-workflows/httproute.yaml`
- Create: `services/argo/argo-workflows/basic-auth-middleware.yaml`

Create gateway and httproute following same pattern as Rollouts. Basic-auth middleware for Traefik.

Remove limits from Helm values.

Commit: `feat: add Argo Workflows namespace, Helm values, gateway with basic-auth`

---

## Task 4: AnalysisTemplates

**Files:**
- Create: `services/argo/analysis-templates/success-rate.yaml`
- Create: `services/argo/analysis-templates/latency-check.yaml`
- Create: `services/argo/analysis-templates/error-rate.yaml`

Copy from source verbatim. These are ClusterAnalysisTemplates that query Prometheus.

Commit: `feat: add Argo Rollouts AnalysisTemplates (success-rate, latency, error-rate)`

---

## Task 5: Monitoring

**Files:**
- Copy all from source `services/argo/monitoring/`

Expected: kustomization.yaml, 3 ServiceMonitors, 3 Grafana dashboards, argocd-alerts PrometheusRule.

Commit: `feat: add Argo monitoring (ServiceMonitors, alerts, 3 Grafana dashboards)`

---

## Task 6: Root Kustomization

**Files:**
- Create: `services/argo/kustomization.yaml`

Reference all base manifests. OAuth2-proxy resources NOT included (deployed explicitly later).

Validate: `kubectl kustomize services/argo/`

Commit: `feat: add Argo root kustomization`

---

## Task 7: Deploy Script (deploy-argo.sh)

**Files:**
- Create: `scripts/deploy-argo.sh`

7 phases following established patterns:
1. Namespaces
2. ESO SecretStores
3. ArgoCD Helm install (with substituted values, HA, Redis)
4. Argo Rollouts Helm install
5. Argo Workflows Helm install
6. Gateways + HTTPRoutes + basic-auth + AnalysisTemplates
7. Monitoring + Verify

Add env vars: `HELM_CHART_ARGOCD`, `HELM_REPO_ARGOCD`, `HELM_CHART_ROLLOUTS`, `HELM_CHART_WORKFLOWS`, `ARGO_BASIC_AUTH_PASS`, `WORKFLOWS_BASIC_AUTH_PASS`.

Commit: `feat: add deploy-argo.sh orchestrator (7 phases)`

---

## Task 8: Update .env.example + subst.sh

Add Argo-specific env vars and CHANGEME tokens.

Commit: `feat: add Argo env vars and CHANGEME tokens`

---

## Task 9: MANIFEST.yaml + README (tech-doc-keeper)

Create per-service bill of materials and documentation.

Commit: `docs: add Argo MANIFEST.yaml and README`

---

## Task 10: Security Scrub (security-sentinel)

Standard checks: org-specific info, limits, CHANGEME coverage, kustomize build, shellcheck.

---

## Task 11: Push + CI

Push and monitor CI.
