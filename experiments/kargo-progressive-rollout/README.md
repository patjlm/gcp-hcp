# Kargo Progressive Rollout Experiment

This experiment demonstrates how [Kargo](https://kargo.io) would orchestrate progressive rollout across the GCP-HCP platform architecture. It includes fake Terraform configs, dummy Helm charts, ArgoCD Application templates, and complete Kargo CRDs.

**This is a reference experiment, not a deployable system.** The Kargo CRDs are valid and could be applied to a cluster with Kargo installed, but the Warehouses reference fake image registries and the Terraform configs have no real resources.

## What This Demonstrates

1. **Two-pipeline model** — Component-level promotion for int+stage, bundle promotion for prod
2. **Component-level promotion** — Each app has its own Warehouse; individual updates flow independently through int and stage
3. **Bundle promotion** — The bundle warehouse watches stage-main output; prod receives the exact validated state as an atomic unit
4. **Pipeline handoff** — Component pipelines write to stage-main values files; bundle warehouse reads them to create prod-bound Freight
5. **Git-only promotion** — Kargo commits version updates to Git; ArgoCD syncs autonomously (no `argocd-update`)
6. **Commit SHA pinning** — `targetRevision` is a specific commit, not a branch, ensuring each target runs exactly what was promoted
7. **Self-referencing loop prevention** — Warehouse `includePaths`/`excludePaths` prevent promotion commits from triggering new Freight
8. **Terraform integration** — `hcl-update` modifies `.tfvars` in Git; Atlantis/TF Cloud handles plan/apply
9. **Verification** — AnalysisTemplates using Kube Jobs, Prometheus queries, and HTTP checks

## Topology

### Two-Pipeline Architecture

```
PIPELINE 1 — Component-Level (integration + stage)
Each component warehouse creates independent Freight per app.

  myapp-warehouse ─────────┐
  cls-backend-warehouse ───┤──→ int-e2e-us-central1  (direct, auto)
  monitoring-warehouse ────┘──→ int-main-us-central1 (direct, auto, parallel with e2e)
                                    │
                                    ▼ (manual approval for env gate)
                                 stage-canary-us-west1
                                    │
                                    ▼ (auto after verify)
                              ┌─ stage-main-us-west1  ← writes argocd/targets/stage/main/us-west1/values.yaml
                              └─ stage-main-eu-west1  ← writes argocd/targets/stage/main/eu-west1/values.yaml

                                         ┃ HANDOFF
                                         ┃ Bundle warehouse watches stage-main values files.
                                         ┃ When component promotions write versions there,
                                         ┃ the bundle warehouse detects the change and
                                         ┃ creates Freight containing that validated state.
                                         ▼

PIPELINE 2 — Bundle-Level (production)
Bundle warehouse reads the committed stage-main state as a single unit.

  platform-bundle-warehouse
    watches: argocd/targets/stage/main/**/values.yaml
    watches: terraform/config/stage/main/**
                  │
                  ▼ (manual approval for env gate)
            prod-canary-us-east1
                  │
                  ▼ (auto after verify)
            ┌─ prod-main-us-east1
            └─ prod-main-eu-west4
```

### Apps

| App | Type | Image | Purpose |
|-----|------|-------|---------|
| myapp | Service | `us-docker.pkg.dev/gcp-hcp-artifacts/images/myapp` | Simple web service |
| cls-backend | Service | `us-docker.pkg.dev/gcp-hcp-artifacts/images/cls-backend` | CLS backend API |
| monitoring | Service | `us-docker.pkg.dev/gcp-hcp-artifacts/images/monitoring` | Monitoring stack |
| platform-config | Config | (none) | Platform configuration (Git-only) |

### Promotion Flow

**Pipeline 1 (component-level):**

1. New `myapp:v1.1.0` image pushed to registry
2. `myapp` warehouse detects new tag, creates Freight containing `myapp:v1.1.0`
3. Freight auto-promotes to `int-e2e-us-central1` AND `int-main-us-central1` (parallel):
   - Kargo runs `argocd-gitops-promote` PromotionTask
   - Updates `apps.myapp.image.tag` in the target's `values.yaml`
   - Commits and pushes to Git
   - ArgoCD on each cluster detects the change, re-syncs myapp
4. Verification runs in both. After int-main passes, Freight is eligible for `stage-canary-us-west1` (manual approval)
5. After stage-canary verifies, auto-promotes to `stage-main-us-west1` and `stage-main-eu-west1` (fan-out)
6. Stage-main promotion writes updated versions to `argocd/targets/stage/main/*/values.yaml`

**Pipeline 2 (bundle-level):**

7. Bundle warehouse detects the stage-main values file change (from step 6)
8. Creates Freight containing the git commit with all validated versions
9. Operator manually approves the bundle Freight for `prod-canary-us-east1`
10. `bundle-promote` task reads versions from stage-main values, writes them to prod target values
11. After prod-canary verifies, auto-promotes to `prod-main-us-east1` and `prod-main-eu-west4`

## Self-Referencing Loop Prevention

### The Problem

Kargo and ArgoCD both reference the same git repo. When Kargo promotes, it commits updated `values.yaml` files. This creates a new commit on the branch. If the Warehouse watches the entire branch, it would detect the new commit, create new Freight, trigger new promotion — infinite loop.

### The Solution

Warehouses use `includePaths` and `excludePaths` to filter which changes trigger new Freight:

**Component warehouses** (myapp, cls-backend, monitoring) watch image registries + their own chart source code (`helm/charts/{app}/**`). The `includePaths` is narrow enough that promotion commits (which touch `argocd/targets/**`) are never matched.

**Bundle warehouse** watches stage-main output and excludes prod paths:

```yaml
# warehouses/platform-bundle.yaml (simplified)
spec:
  subscriptions:
  - git:
      repoURL: https://github.com/openshift/gcp-hcp-infra.git
      branch: main
      includePaths:
      - experiments/kargo-progressive-rollout/argocd/targets/stage/main/**    # Stage-main output
      - experiments/kargo-progressive-rollout/terraform/config/stage/main/**  # Stage-main infra
      excludePaths:
      - experiments/kargo-progressive-rollout/argocd/targets/prod/**  # Prod promotion targets
      - experiments/kargo-progressive-rollout/terraform/config/prod/** # Prod promotion targets
```

**What triggers new component Freight:** New image tags in registries, or changes to `helm/charts/{app}/**`.

**What triggers new bundle Freight:** Changes to `argocd/targets/stage/main/**/values.yaml` (written by Pipeline 1 promotions).

**What does NOT trigger any Freight:** Promotion commits to `argocd/targets/integration/**`, `argocd/targets/stage/canary/**`, or `argocd/targets/prod/**`.

### Loop Prevention Analysis

All warehouses reference the same git repo (`main` branch). Here's why no loops occur:

| Promotion writes to | Component warehouses | Bundle warehouse | Loop? |
|---------------------|---------------------|-----------------|-------|
| `argocd/targets/integration/**` | Not in `includePaths` | Not in `includePaths` | No |
| `argocd/targets/stage/canary/**` | Not in `includePaths` | Not in `includePaths` | No |
| `argocd/targets/stage/main/**` | Not in `includePaths` | **IN `includePaths`** (intentional — this IS the handoff) | No loop — creates bundle Freight, which is a different pipeline |
| `argocd/targets/prod/**` | Not in `includePaths` | Not in `includePaths` | No |
| `terraform/config/**` | Not in `includePaths` | Not in `includePaths` (prod excluded) | No |

The only cross-pipeline trigger is intentional: component promotions to stage-main create bundle Freight for prod. Bundle Freight promotions to prod write to `argocd/targets/prod/**` which no warehouse watches. No cycles.

### Multi-Origin Promotion Behavior

In Pipeline 1, each stage accepts Freight from 3 component warehouses. Key behaviors:
- Each warehouse's Freight is promoted **independently** — a myapp update does not wait for cls-backend
- The `argocd-gitops-promote` task updates ALL image tags on every promotion. For the active Freight, `imageFrom()` returns the new version. For other origins, it returns the most recently promoted version. This means the values file always reflects the latest known state of all components.
- This is **component-triggered, not atomic**: each individual component change flows through int → stage independently. The bundle warehouse then captures the accumulated state for prod.

### Commit SHA Pinning

Each target's `values.yaml` contains a `git_revision` field set to the Freight's commit SHA:

```yaml
git_revision: a1b2c3d4e5f6   # Specific commit, NOT "main"
```

ArgoCD Applications use this as `targetRevision`, ensuring each target runs the exact code from its promoted Freight — not whatever happens to be on HEAD.

## Directory Layout

```
.
├── README.md                  ← You are here
│
├── helm/charts/               ← Dummy Helm charts (what apps actually deploy)
│   ├── myapp/                   Chart.yaml, values.yaml, templates/deployment.yaml
│   ├── cls-backend/             Same structure
│   ├── monitoring/              Same structure
│   └── platform-config/        Chart.yaml, values.yaml, templates/configmap.yaml
│
├── argocd/
│   ├── base-chart/            ← Shared Helm chart generating ArgoCD Applications
│   │   ├── Chart.yaml
│   │   └── templates/           One Application template per app
│   └── targets/               ← Per-target values (KARGO WRITES HERE)
│       └── {env}/{sector}/{region}/values.yaml
│
├── terraform/
│   ├── modules/region/        ← Fake Terraform module
│   │   ├── main.tf
│   │   └── variables.tf
│   └── config/                ← Per-target TF configs (KARGO WRITES HERE)
│       └── {env}/{sector}/{region}/
│           ├── main.tf
│           └── terraform.tfvars
│
├── verification/              ← Verification implementations (buildable)
│   ├── health-check/            Kube Job health check
│   │   ├── check.sh               Script (checks STAGE_NAME, GIT_REVISION)
│   │   └── Dockerfile             → quay.io/patmarti/kargo-health-check
│   └── health-server/           HTTP health endpoint
│       ├── main.go                Go server (/healthz → {"status":"healthy"})
│       ├── Dockerfile             → quay.io/patmarti/kargo-health-server
│       └── manifests.yaml         Deployment + Service
│
└── kargo/                     ← Kargo CRDs
    ├── project.yaml             Project definition
    ├── project-config.yaml      Auto-promotion policies
    ├── warehouses/              What to watch for new versions
    │   ├── myapp.yaml             Component-level (image only)
    │   ├── cls-backend.yaml       Component-level (image only)
    │   ├── monitoring.yaml        Component-level (image only)
    │   ├── platform-bundle.yaml   Bundle (watches stage-main output for prod pipeline)
    │   └── infra.yaml             Infrastructure (git path for TF modules)
    ├── promotion-tasks/         Reusable promotion step sequences
    │   ├── argocd-gitops-promote.yaml   Pipeline 1: update ArgoCD values + git commit
    │   ├── terraform-promote.yaml       Pipeline 1: update terraform.tfvars + git commit
    │   └── bundle-promote.yaml          Pipeline 2: copy stage-main versions to prod target
    ├── stages/                  The promotion DAG
    │   ├── int-e2e-us-central1.yaml       Pipeline 1 (component, direct)
    │   ├── int-main-us-central1.yaml      Pipeline 1 (component, direct, parallel with e2e)
    │   ├── stage-canary-us-west1.yaml     Pipeline 1 (component, from int-main, manual gate)
    │   ├── stage-main-us-west1.yaml       Pipeline 1 (component, from stage-canary)
    │   ├── stage-main-eu-west1.yaml       Pipeline 1 (component, from stage-canary)
    │   ├── prod-canary-us-east1.yaml      Pipeline 2 (bundle, direct, manual gate)
    │   ├── prod-main-us-east1.yaml        Pipeline 2 (bundle, from prod-canary)
    │   └── prod-main-eu-west4.yaml        Pipeline 2 (bundle, from prod-canary)
    └── verification/            Post-promotion health checks
        ├── platform-health-check.yaml   Kube Job
        ├── prometheus-slo-check.yaml    Prometheus query
        └── http-api-check.yaml          HTTP endpoint check
```

## What Kargo Updates During Promotion

### ArgoCD Values (via `yaml-update`)

File: `argocd/targets/{env}/{sector}/{region}/values.yaml`

| Key | Source | Purpose |
|-----|--------|---------|
| `git_revision` | Freight commit SHA | Pins ArgoCD `targetRevision` |
| `apps.myapp.image.tag` | Freight image discovery | Updates myapp image |
| `apps.cls-backend.image.tag` | Freight image discovery | Updates cls-backend image |
| `apps.monitoring.image.tag` | Freight image discovery | Updates monitoring image |

### Terraform Variables (via `hcl-update`)

File: `terraform/config/{env}/{sector}/{region}/terraform.tfvars`

| Key | Source | Purpose |
|-----|--------|---------|
| `module_version` | Freight commit SHA | Pins Terraform module version |

## Freeze / Fast Track

**Freeze**: Set `autoPromotionEnabled: false` in `project-config.yaml` for the scope you want to freeze (per-stage, per-environment glob, or global `*`).

**Fast Track**: Use `kargo approve --freight <id> --stage prod-canary-us-east1` to bypass upstream requirements. The target stage's verification still runs.

## How to Demo

### Prerequisites

1. A Kubernetes cluster with Kargo installed
2. Build and push the verification images:

```bash
cd experiments/kargo-progressive-rollout/verification

# Health check job (Kube Job verification)
docker build -t quay.io/patmarti/kargo-health-check:latest health-check/
docker push quay.io/patmarti/kargo-health-check:latest

# Health server (HTTP verification endpoint)
docker build -t quay.io/patmarti/kargo-health-server:latest health-server/
docker push quay.io/patmarti/kargo-health-server:latest
```

3. Deploy the health server:

```bash
kubectl apply -f experiments/kargo-progressive-rollout/verification/health-server/manifests.yaml
```

### Deploy the Experiment

```bash
# Create the project
kubectl apply -f experiments/kargo-progressive-rollout/kargo/project.yaml

# Wait for namespace to be created, then apply everything else
kubectl apply -f experiments/kargo-progressive-rollout/kargo/project-config.yaml
kubectl apply -f experiments/kargo-progressive-rollout/kargo/warehouses/
kubectl apply -f experiments/kargo-progressive-rollout/kargo/verification/
kubectl apply -f experiments/kargo-progressive-rollout/kargo/promotion-tasks/
kubectl apply -f experiments/kargo-progressive-rollout/kargo/stages/
```

### Manual Approval (Environment Gates)

`stage-canary-*` and `prod-canary-*` stages have `autoPromotionEnabled: false`. Freight will queue at these stages until manually promoted.

```bash
# List available Freight for a stage
kargo get freight --project progressive-rollout-experiment

# Manually promote Freight to stage-canary (environment gate)
kargo promote --project progressive-rollout-experiment \
  --freight <freight-id> \
  --stage stage-canary-us-west1

# Manually promote bundle Freight to prod-canary (environment gate)
kargo promote --project progressive-rollout-experiment \
  --freight <freight-id> \
  --stage prod-canary-us-east1
```

Or use the Kargo UI: drag Freight from the timeline onto the target stage.

### Testing Verification Failure

Set `FORCE_FAIL=true` on the health check to simulate a failed verification:

```bash
# Edit the AnalysisTemplate to add FORCE_FAIL env var
# The health check job will fail, Freight will NOT be marked as verified,
# and downstream stages will not receive it — automatic halt.
```

### Freeze / Unfreeze

```bash
# Freeze all production promotions
kubectl patch projectconfig progressive-rollout-experiment \
  -n progressive-rollout-experiment \
  --type merge \
  -p '{"spec":{"promotionPolicies":[{"stageSelector":{"name":"glob:prod-*"},"autoPromotionEnabled":false}]}}'

# Unfreeze (re-enable auto-promotion for prod-main)
kubectl patch projectconfig progressive-rollout-experiment \
  -n progressive-rollout-experiment \
  --type merge \
  -p '{"spec":{"promotionPolicies":[{"stageSelector":{"name":"glob:prod-main-*"},"autoPromotionEnabled":true}]}}'
```

## Related Documents

- [Progressive Rollout Requirements & Kargo Evaluation](../../studies/progressive-rollout/progressive-rollout.md)
- [Detailed Kargo Research](../../studies/progressive-rollout/initial-kargo-research.md)
- [Spinnaker Evaluation](../../studies/progressive-rollout/initial-spinnaker-research.md)
