# Comprehensive Kargo.io Evaluation for GCP-HCP Progressive Rollout

This document synthesizes research from official Kargo documentation, GitHub issues, release notes, and community resources as of April 2026 (Kargo v1.10.2).

---

## 1. Kargo Architecture & Core Concepts

### What is Kargo?

Kargo is an **unopinionated continuous promotion platform** — a Kubernetes-native application lifecycle orchestrator built and maintained by Akuity, the company founded by the creators of the Argo project. It sits as an orchestration layer *above* ArgoCD and fills the gap that ArgoCD deliberately leaves: orchestrating the *promotion* of desired state changes from one environment to the next.

Kargo does not replace ArgoCD. ArgoCD's role remains unchanged: sync manifests from Git to clusters and report health. Kargo's role is to decide *what* to put in Git and *when*, based on policies, verifications, and approvals.

The project is open source (Apache-2.0) on GitHub at `akuity/kargo`. As of April 22, 2026, it is at **v1.10.2**, has **3.2k GitHub stars**, 363 forks, and 195 releases. It is written primarily in Go (66%) and TypeScript (32%).

### Core Concepts

**Project**: The unit of tenancy. Each Project maps to a Kubernetes namespace, making RBAC straightforward. Projects own all the downstream resources (Warehouses, Stages, etc.).

**Warehouse**: The source of Freight. A Warehouse monitors one or more upstream repositories — container image registries, Git repositories, Helm chart repositories — and packages the latest discovered revisions into a new Freight object whenever a new revision is detected. Warehouses support path-based filtering (`includePaths`/`excludePaths`) for monorepo support, and since v1.6 also respond to inbound webhooks from GitHub, GitLab, Docker Hub, and Quay.

```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Warehouse
metadata:
  name: my-app
  namespace: my-project
spec:
  subscriptions:
  - image:
      repoURL: my-registry.io/my-app
      semverConstraint: "^1.0.0"
      discoveryLimit: 10
  - git:
      repoURL: https://github.com/my-org/my-gitops-repo.git
      branch: main
      includePaths:
      - base/**
      - charts/**
```

**Freight**: A Freight is an immutable Kubernetes custom resource that groups a set of specific artifact revisions into a single promotable unit. Think of it as a shipping container that bundles together a container image at tag `v1.2.3`, a Git commit at SHA `abc123`, and a Helm chart at version `2.1.0`. These artifacts always travel together through the pipeline as a unit, which is critical for bundle promotion.

```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Freight
metadata:
  name: f5f87aa2...
  namespace: my-project
spec:
  warehouse: my-app
  commits:
  - repoURL: https://github.com/my-org/my-gitops-repo.git
    id: abc123def456
  images:
  - repoURL: my-registry.io/my-app
    tag: v1.2.3
    digest: sha256:...
  charts:
  - repoURL: https://charts.example.com
    name: my-chart
    version: 2.1.0
```

**Stage**: The promotion target. A Stage represents some desired state that needs to be altered during a promotion. Most users think of stages as environments, but they can represent anything (an entire environment, a single microservice, a geographic shard). Stages are connected into a directed acyclic graph (DAG) that forms the pipeline.

**Promotion**: A Kubernetes resource representing a request to move a specific piece of Freight into a specific Stage. When triggered (manually or automatically), Kargo creates a Promotion object and executes the steps defined in the Stage's `promotionTemplate`.

**PromotionTask / ClusterPromotionTask**: Reusable, parameterized sequences of promotion steps introduced in v1.2. Analogous to functions or subroutines — they eliminate copy-paste across many Stages. `ClusterPromotionTask` is cluster-scoped and available across all Projects.

**ProjectConfig**: Introduced in v1.5. Defines project-level promotion policies, primarily which Stages are eligible for auto-promotion. Separation from the `Project` resource enables finer-grained RBAC.

### ArgoCD Integration

The integration model is explicit and annotation-based. Any ArgoCD Application that Kargo may update must carry this annotation:

```yaml
annotations:
  kargo.akuity.io/authorized-stage: "my-project:my-stage"
```

This proves that a user with permission to edit the Application has consented to Kargo managing it. The `argocd-update` promotion step is then the runtime mechanism by which Kargo triggers ArgoCD syncs. After a successful `argocd-update` step, Kargo registers a health check that factors the Application's health into the Stage's overall health — this prevents verification from starting before deployments stabilize.

### Git Integration

Kargo commits changes to Git as part of promotion. The full flow is: `git-clone` → (modify files) → `git-commit` → `git-push` → `argocd-update`. This means Git always reflects the desired state, maintaining GitOps integrity.

---

## 2. Kargo's Promotion Model

### How Promotion Between Stages Works

Promotion is a two-phase event:

1. **Freight becomes available**: A Stage declares what Freight it accepts and from where. For the first Stage, this is typically "direct from Warehouse X." For downstream stages, it is "from Stage Y, after verification." Freight becomes available when it has been verified in all required upstream Stages (or soak time has elapsed, whichever the Stage requires).

2. **Promotion executes**: Either automatically (if auto-promotion is enabled in `ProjectConfig`) or manually (via CLI or UI), a Promotion object is created. Kargo then executes the Stage's `promotionTemplate` steps sequentially.

### Stage Configuration for Multi-Stage Pipelines

```yaml
# First stage: accepts Freight directly from Warehouse
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: test
  namespace: my-project
spec:
  requestedFreight:
  - origin:
      kind: Warehouse
      name: my-app
    sources:
      direct: true           # Accept directly from Warehouse
  promotionTemplate:
    spec:
      steps: [...]
  verification:
    analysisTemplates:
    - name: integration-test

---
# Second stage: only accepts Freight verified in 'test'
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: staging
  namespace: my-project
spec:
  requestedFreight:
  - origin:
      kind: Warehouse
      name: my-app
    sources:
      stages:
      - test                 # Must have passed through 'test'
  promotionTemplate:
    spec:
      steps: [...]

---
# Third stage: requires verification in BOTH qa AND uat (fan-in)
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: prod
  namespace: my-project
spec:
  requestedFreight:
  - origin:
      kind: Warehouse
      name: my-app
    sources:
      stages:
      - qa
      - uat                  # Freight must pass BOTH before eligible
      requiredSoakTime: 2h   # Must remain verified for 2h
  promotionTemplate:
    spec:
      steps: [...]
```

### Built-in Promotion Steps (Complete List as of v1.10)

The built-in step library is extensive:

**Git Operations:**
- `git-clone` — Clone repo and check out one or more branches/commits to working trees
- `git-commit` — Commit changes in a working tree
- `git-push` — Push committed changes to remote (with built-in retry/rebase for concurrent pushes)
- `git-open-pr` — Open a PR on GitHub, GitLab, Gitea, or Bitbucket
- `git-wait-for-pr` — Wait for a PR to be merged or closed
- `git-merge-pr` — Merge an open PR
- `git-tag` — Create a new tag
- `git-clear` — Delete all contents of a working tree
- `github-push` — Push via GitHub API (enables verified commits without SSH keys)

**File and Configuration:**
- `copy` — Copy files or directories
- `delete` — Remove files or directories
- `yaml-update` — Update arbitrary YAML key paths
- `yaml-parse` — Extract values from YAML
- `yaml-merge` — Merge multiple YAML files
- `json-update`, `json-parse` — JSON equivalents
- `toml-update`, `toml-parse` — TOML equivalents
- `hcl-update` — Update HCL file attribute values (Terraform/OpenTofu configs)

**Kustomize:**
- `kustomize-set-image` — Update `kustomization.yaml` image references
- `kustomize-build` — Render a Kustomize directory to a file or directory

**Helm:**
- `helm-update-chart` — Update `Chart.yaml` dependencies
- `helm-template` — Render a Helm chart to files

**ArgoCD:**
- `argocd-update` — Update ArgoCD Application resources and register health checks
- `argocd-wait` — Wait for ArgoCD Applications to reach desired conditions

**External Integrations (Open Source):**
- `http` — Make HTTP/S GET/POST/etc. requests with success/failure expressions
- `http-download` — Download a file via HTTP/S

**OCI/Container:**
- `oci-download` — Download OCI artifacts from a registry
- `oci-push` — Copy or retag OCI artifacts between registries

**Data/Control:**
- `untar` — Extract tar archives
- `compose-output` — Compose outputs from multiple steps
- `set-metadata` — Update metadata on Stage or Freight resources
- `set-freight-alias` — Update Freight aliases
- `fail` — Fail the promotion unconditionally

**Akuity Platform Only:**
- `tf-plan` — Execute an OpenTofu/Terraform plan **(Platform only, v1.9+)**
- `tf-apply` — Apply an OpenTofu/Terraform configuration or plan **(Platform only, v1.9+)**
- `tf-output` — Retrieve outputs from OpenTofu/Terraform state **(Platform only, v1.9+)**
- `jira` — Manage Jira issues and comments **(Platform only, v1.6+)**
- `snow-create`, `snow-update`, `snow-delete`, `snow-query-for-records`, `snow-wait-for-condition` — ServiceNow integration **(Platform only, v1.9+)**
- `jfrog-evidence` — Manage artifact evidence in JFrog Artifactory **(Platform only, v1.7+)**
- `gha-dispatch-workflow`, `gha-wait-for-workflow` — GitHub Actions integration **(Platform only, v1.8+)**
- `send-message` — Send notifications (Slack, email, etc.) **(Platform only, v1.8+)**
- `custom-steps` — Execute arbitrary commands in a user-provided OCI image **(Platform only, v1.10+, Alpha)**

### Bundle Promotion

Yes, Kargo natively supports bundle promotion. A single Freight object bundles multiple artifacts (image + Git commit + Helm chart), and this bundle moves atomically through the pipeline. All stages receive the same bundle. The Warehouse defines what goes into the bundle via its subscriptions.

### Conditional Steps (v1.3+, enhanced in v1.5)

```yaml
steps:
- uses: some-step
  as: step1
- uses: cleanup-step
  if: ${{ failure() }}     # Only runs if a prior step failed
- uses: notify-step
  if: ${{ always() }}      # Runs regardless of prior step outcomes
- uses: next-step
  if: ${{ outputs.step1.result == "ok" }}  # Conditional on output
```

### PromotionTask: Reusable Step Sequences

```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: ClusterPromotionTask
metadata:
  name: helm-gitops-promote
spec:
  vars:
  - name: gitRepo
  - name: imageRepo
  - name: appName
  steps:
  - uses: git-clone
    config:
      repoURL: ${{ vars.gitRepo }}
      checkout:
      - commit: ${{ commitFrom(vars.gitRepo).ID }}
        path: ./src
      - branch: stage/${{ ctx.stage }}
        create: true
        path: ./out
  - uses: git-clear
    config:
      path: ./out
  - uses: yaml-update
    as: update-image
    config:
      path: ./src/environments/${{ ctx.stage }}/values.yaml
      updates:
      - key: image.tag
        value: ${{ imageFrom(vars.imageRepo).Tag }}
  - uses: git-commit
    as: commit
    config:
      path: ./out
      messageFromSteps:
      - update-image
  - uses: git-push
    config:
      path: ./out
  - uses: argocd-update
    config:
      apps:
      - name: ${{ vars.appName }}-${{ ctx.stage }}
        sources:
        - repoURL: ${{ vars.gitRepo }}
          desiredRevision: ${{ outputs.commit.commit }}

---
# Reference in a Stage:
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: int-us-central1
spec:
  requestedFreight:
  - origin:
      kind: Warehouse
      name: my-app
    sources:
      direct: true
  promotionTemplate:
    spec:
      vars:
      - name: gitRepo
        value: https://github.com/my-org/gitops-repo.git
      - name: imageRepo
        value: my-registry.io/my-app
      - name: appName
        value: my-app
      steps:
      - task:
          name: helm-gitops-promote
          kind: ClusterPromotionTask
```

---

## 3. Kargo and ArgoCD Integration

### Core Integration Pattern

Kargo integrates with ArgoCD through the `argocd-update` step and the `kargo.akuity.io/authorized-stage` annotation. The annotation is the security boundary — only Applications explicitly annotated can be managed by Kargo's controllers.

For ApplicationSet-generated Applications, the annotation can be templated:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: my-app
  namespace: argocd
spec:
  generators:
  - list:
      elements:
      - stage: int
      - stage: stage
      - stage: prod
  template:
    metadata:
      name: "my-app-{{stage}}"
      annotations:
        kargo.akuity.io/authorized-stage: "my-project:{{stage}}"
    spec:
      ...
```

This is a very common and well-supported pattern. Kargo can drive promotions for ApplicationSet-generated Applications just as easily as individually defined Applications.

### What the `argocd-update` Step Can Do

The step supports:
- **Hard refresh**: Force ArgoCD to re-fetch from Git without updating anything (for cases where Kargo pushed to Git and just needs ArgoCD to pick it up)
- **Update `targetRevision`**: Set the exact commit/tag/branch for the Application to sync to
- **Update Helm values inline** (without touching Git — less pure GitOps but supported)
- **Update Kustomize image overrides**
- **Select by label selector**: Update all Applications matching `environment=prod` for fan-out scenarios

### App-of-Apps Pattern

Kargo works with app-of-apps, but the integration is indirect. Kargo promotes by committing to Git (which the parent "app-of-apps" ArgoCD Application then picks up and re-renders child Applications). The `argocd-update` step can be used to sync the parent Application after a commit. The key constraint is that the annotation must be on the Application that Kargo directly manages.

A known open issue (#5706) requests the ability for a single ArgoCD Application to be managed by multiple Kargo Stages simultaneously (e.g., multiple parallel Stages each needing to update the same Application). The current annotation supports only one stage per Application. A workaround being discussed is comma-separated stage references, but this is not yet officially supported.

### Multi-Cluster Architecture

Kargo supports multi-cluster deployments through its sharded controller architecture:

- **Standalone**: All components on the Kargo control plane cluster. Suitable for simple setups where all ArgoCD instances are on the same cluster.
- **Distributed/Sharded**: Controllers are deployed to remote clusters (shards) and "phone home" to the centralized control plane via an agent. The control plane has no direct privileged access to shard clusters — only the agent does. This is more secure and scalable.

An active issue (#5646 — "Support GKE Workload Identity Federation for sharded controllers") is directly relevant to GCP environments. Manual RoleBinding creation is currently required in every Project namespace for cross-cluster Workload Identity authentication to work.

---

## 4. Kargo and Git

### How Kargo Commits to Git

The standard Git promotion flow is:

```yaml
steps:
# 1. Clone repo, checking out both source and target branch
- uses: git-clone
  config:
    repoURL: https://github.com/my-org/gitops-repo.git
    checkout:
    - commit: ${{ commitFrom("https://github.com/my-org/gitops-repo.git").ID }}
      path: ./src
    - branch: stage/${{ ctx.stage }}
      create: true          # Creates branch if it doesn't exist
      path: ./out

# 2. Clear the target directory (for clean renders)
- uses: git-clear
  config:
    path: ./out

# 3. Update configuration (many options - shown below)
- uses: yaml-update
  as: update
  config:
    path: ./src/environments/${{ ctx.stage }}/values.yaml
    updates:
    - key: image.tag
      value: ${{ imageFrom("my-registry.io/my-app").Tag }}

# 4. Commit
- uses: git-commit
  as: commit
  config:
    path: ./out
    messageFromSteps:
    - update

# 5. Push (with auto-retry for concurrent pushes to same branch)
- uses: git-push
  config:
    path: ./out

# 6. Tell ArgoCD to sync
- uses: argocd-update
  config:
    apps:
    - name: my-app-${{ ctx.stage }}
      sources:
      - repoURL: https://github.com/my-org/gitops-repo.git
        desiredRevision: ${{ outputs.commit.commit }}
```

### PR-Based Workflows

For production environments where changes should be reviewed before merging:

```yaml
steps:
- uses: git-clone
  config:
    repoURL: https://github.com/my-org/gitops-repo.git
    checkout:
    - branch: main
      path: ./src
    - branch: promote/${{ ctx.stage }}/${{ ctx.promotion }}
      create: true
      path: ./out
- uses: yaml-update
  config:
    path: ./out/environments/prod/values.yaml
    updates:
    - key: image.tag
      value: ${{ imageFrom("my-registry.io/my-app").Tag }}
- uses: git-commit
  config:
    path: ./out
- uses: git-push
  config:
    path: ./out
- uses: git-open-pr
  as: pr
  config:
    repoURL: https://github.com/my-org/gitops-repo.git
    sourceBranch: promote/${{ ctx.stage }}/${{ ctx.promotion }}
    targetBranch: main
    title: "Promote ${{ ctx.freight }} to ${{ ctx.stage }}"
- uses: git-wait-for-pr
  config:
    repoURL: https://github.com/my-org/gitops-repo.git
    prNumber: ${{ outputs.pr.prNumber }}
```

### Repository Layout Support

Kargo supports all common GitOps repository layouts:

- **Helm values overrides**: Stage-specific `values-<stage>.yaml` files updated via `yaml-update` or `helm-update-chart`
- **Kustomize overlays**: `kustomize-set-image` + `kustomize-build` for rendered manifests
- **Rendered branches**: Each Stage has its own branch (`stage/test`, `stage/prod`) with fully-rendered manifests
- **Monorepos**: Supported with `includePaths`/`excludePaths` on Warehouse subscriptions
- **Single branch with separate input/output directories**: Supported but requires careful path filtering to prevent feedback loops

### Replacing a Python Rendering Script

Kargo can partially replace your Python rendering script. The `yaml-update`, `helm-template`, and `kustomize-build` steps cover most rendering scenarios. However, for complex hierarchical overrides (environment/sector/region level), your current Python script logic would need to be replicated in either:
1. A sequence of `yaml-update` steps with expressions
2. A `custom-steps` step (Akuity Platform only, v1.10+, Alpha) using your Python script in a container
3. The `http` step calling an external service that performs the rendering

The most practical approach for your architecture is likely to keep the rendering logic but invoke it via a containerized `custom-steps` step, or restructure the config hierarchy to use Helm with stage-specific values files that Kargo's built-in steps can manipulate directly.

---

## 5. Multi-Environment & Multi-Region Support

### Modeling Environment → Sector → Region Hierarchies

Kargo's Stage model is flexible enough to represent any hierarchy. Stages are just named promotion targets — there is no constraint on what they represent. The DAG can be structured as:

```
Warehouse
    │
    ▼
int-canary-us-central1 (Stage) ──→ int-canary-verification
    │
    ▼ (after verification)
int-main-us-central1 (Stage) ─┐
int-main-us-east1 (Stage)    ─┤─→ int-main-fanin (Control Flow Stage)
int-main-eu-west1 (Stage)    ─┘
    │
    ▼ (after all int-main pass)
stage-canary-us-central1 (Stage)
    ...
```

Example Stage for a specific region:

```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: int-canary-us-central1
  namespace: my-project
  labels:
    environment: integration
    sector: canary
    region: us-central1
spec:
  requestedFreight:
  - origin:
      kind: Warehouse
      name: my-app
    sources:
      direct: true
  promotionTemplate:
    spec:
      steps:
      - task:
          name: argocd-gitops-promote
          kind: ClusterPromotionTask
        vars:
        - name: appName
          value: my-app-int-us-central1
  verification:
    analysisTemplates:
    - name: e2e-health-check

---
# Fan-in: all int-main regions must pass before staging
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: int-main-fanin
  namespace: my-project
spec:
  requestedFreight:
  - origin:
      kind: Warehouse
      name: my-app
    sources:
      stages:
      - int-main-us-central1
      - int-main-us-east1
      - int-main-eu-west1      # All three must verify
  # No promotionTemplate: this is a Control Flow Stage
  # It just serves as a synchronization gate

---
# Stage environment is now eligible once int-main-fanin is satisfied
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: stage-canary-us-central1
spec:
  requestedFreight:
  - origin:
      kind: Warehouse
      name: my-app
    sources:
      stages:
      - int-main-fanin
  promotionTemplate:
    spec:
      steps: [...]
```

### Fan-Out: One Stage Promoting to Many Downstream Stages

Fan-out is implemented implicitly: when multiple downstream Stages all subscribe to the same upstream Stage (or Control Flow Stage), they can all receive the Freight simultaneously. Auto-promotion will trigger them in parallel.

### Fan-In: All Regions Must Pass Before Next Environment

Fan-in is implemented via the `sources.stages` list in a downstream Stage's `requestedFreight`. When multiple upstream Stages are listed, the Freight must be verified in **all** of them before becoming available to the downstream Stage. A Control Flow Stage is the typical pattern for this:

```yaml
# Control Flow Stage: no promotion template, just a sync gate
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: int-all-regions-gate
spec:
  requestedFreight:
  - origin:
      kind: Warehouse
      name: my-app
    sources:
      stages:
      - int-us-central1
      - int-us-east1
      - int-eu-west1
      - int-ap-southeast1
  # No promotionTemplate - this is the fan-in gate
```

### Soak Times

Stages can require Freight to remain verified in upstream Stages for a minimum duration before becoming promotable:

```yaml
requestedFreight:
- origin:
    kind: Warehouse
    name: my-app
  sources:
    stages:
    - staging
    requiredSoakTime: 24h   # Must have been verified in staging for 24h
```

### Scaling Limitation: No StageSet Yet

Kargo does not currently have a `StageSet` resource (analogous to ArgoCD's `ApplicationSet`). Managing many similar Stages (e.g., 10+ regions) requires either:
1. Generating Stage manifests with Helm (recommended workaround by maintainers)
2. Writing a script to generate Stage YAML
3. Waiting for the planned `StageSet` feature (no confirmed timeline)

This is a meaningful operational gap for large-scale multi-region deployments.

---

## 6. Fast Track / Emergency Rollouts

### Bypassing the Normal Pipeline via Manual Approval

The primary mechanism for fast-tracking is **manual Freight approval**:

```bash
# Approve freight to skip directly to prod, bypassing int and stage verification
kargo approve \
  --project my-project \
  --freight <freight-name-or-id> \
  --stage prod
```

This marks the Freight as manually approved for the target Stage, making it available to that Stage without requiring it to have been verified in any upstream Stage. It effectively skips all intervening gates.

**Important nuance** (confirmed via GitHub Discussion #3887): Manual approval bypasses *upstream* requirements only. Once the approved Freight is promoted to the target Stage, that Stage's own verification (`analysisTemplates`) will still run. As of v1.4.2 this behavior is confirmed. There is currently no way to suppress post-promotion verification for an individual Freight piece — it always runs if configured on the Stage.

### Modeling a Dedicated Fast-Track Path in the DAG

An alternative architecture is to model a fast-track as a parallel path in the DAG:

```
Warehouse
├── normal path: int → stage-canary → stage-main → prod
└── fast-track path: hotfix-stage → prod-fast-track
                                        (manual approval required)
```

The `prod-fast-track` Stage subscribes only to `hotfix-stage`, which itself requires manual approval (auto-promotion disabled). The `prod` Stage subscribes only to the normal path. This gives you a two-button system: standard flow and fast track.

---

## 7. Freeze / Halt Rollout

### Disabling Auto-Promotion (Freeze)

To prevent new Freight from automatically promoting to a Stage, update the `ProjectConfig`:

```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: ProjectConfig
metadata:
  name: my-project
  namespace: my-project
spec:
  promotionPolicies:
  - stageSelector:
      name: prod                    # Exact name match
    autoPromotionEnabled: false     # FREEZE: no auto-promotion
  - stageSelector:
      name: "glob:int-*"            # Glob: freeze all int stages
    autoPromotionEnabled: false
  - stageSelector:
      name: "regex:stage-.*"        # Regex: pattern-based freeze
    autoPromotionEnabled: false
  - stageSelector:
      name: "glob:*"                # Freeze EVERYTHING
    autoPromotionEnabled: false
```

Setting `autoPromotionEnabled: false` for a Stage prevents Kargo from automatically creating new Promotions. Existing in-flight Promotions are **not** cancelled — they complete. Only new Freight arrivals are blocked from auto-promoting.

### What Happens to In-Flight Promotions

When you freeze (disable auto-promotion), in-flight Promotions continue to completion. Kargo does not have a built-in "abort all" for running Promotions en masse, but since v1.0, running and pending Promotions can be aborted individually from the UI or via kubectl patching.

If verification is running (an AnalysisRun is active) when a freeze is applied, that verification will continue. The freeze only blocks the *initiation* of new Promotions; it does not interrupt running ones.

### Manual Re-enable (Thaw)

Simply set `autoPromotionEnabled: true` again in the `ProjectConfig`. Any Freight that accumulated while frozen will be eligible for auto-promotion again (specifically the newest available Freight will be promoted).

---

## 8. Verification & Gating

### Verification Mechanisms

Kargo's verification system reuses the `AnalysisTemplate` and `AnalysisRun` CRDs from Argo Rollouts. This is a deliberate choice — those CRDs were designed to be used outside of Argo Rollouts, and Kargo benefits from their rich, battle-tested metric providers.

After a successful Promotion, the Stage enters the **Verifying** phase. Kargo spawns AnalysisRun resources from the referenced AnalysisTemplates. If the AnalysisRun passes, the Freight is marked as **Verified** in that Stage and becomes eligible for downstream promotion.

```yaml
# Stage with verification
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: int-us-central1
spec:
  requestedFreight:
  - origin:
      kind: Warehouse
      name: my-app
    sources:
      direct: true
  verification:
    analysisTemplates:
    - name: e2e-health-check           # AnalysisTemplate in same namespace
    - name: slo-check
      kind: ClusterAnalysisTemplate   # Cluster-scoped template
    args:
    - name: stage-url
      value: ${{ ctx.stage }}.example.com
    - name: commit
      value: ${{ commitFrom("https://github.com/my-org/repo.git").ID }}
```

```yaml
# Example AnalysisTemplate using a Kubernetes Job
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: e2e-health-check
  namespace: my-project
spec:
  args:
  - name: stage-url
  metrics:
  - name: e2e-test
    count: 1
    failureLimit: 0
    provider:
      job:
        spec:
          template:
            spec:
              containers:
              - name: test
                image: my-org/e2e-tests:latest
                env:
                - name: TARGET_URL
                  value: "{{ args.stage-url }}"
              restartPolicy: Never
          backoffLimit: 0
```

### Supported AnalysisTemplate Metric Providers

- Prometheus
- Datadog
- Amazon CloudWatch
- New Relic
- InfluxDB
- Apache SkyWalking
- Graphite
- Kubernetes Jobs (run arbitrary test containers)
- HTTP (call external REST endpoints with JSON response evaluation)

### Querying External Data Sources (e.g., BigQuery)

The `http` promotion step (not the AnalysisTemplate provider) is the primary mechanism for querying external REST APIs. Since BigQuery has a REST API, you can poll it via the `http` step as a gate:

```yaml
steps:
- uses: http
  as: bigquery-gate
  retry:
    timeout: 30m       # Poll for up to 30 minutes
  config:
    method: POST
    url: https://bigquery.googleapis.com/bigquery/v2/projects/my-project/queries
    headers:
    - name: Authorization
      value: "Bearer ${{ secrets.gcp_token }}"
    - name: Content-Type
      value: application/json
    body: |
      {"query": "SELECT passed FROM my_dataset.test_results WHERE run_id = '${{ ctx.promotion }}' LIMIT 1",
       "useLegacySql": false}
    successExpression: response.body.rows[0].f[0].v == "true"
    failureExpression: response.body.rows[0].f[0].v == "false"
- uses: git-clone
  # ... rest of promotion steps
```

Alternatively, a Kubernetes Job within an AnalysisTemplate can run Python/Go code that queries BigQuery and exit 0/1 to signal pass/fail.

### Blocking on ArgoCD Application Health

Kargo automatically delays the start of verification until all ArgoCD Applications registered to the Stage's health checks are in `Healthy` state. This prevents premature test runs against a partially-deployed environment.

### Key Constraint

While a Stage is verifying, no other Promotions to that Stage will run until verification completes (successfully or unsuccessfully). This serializes verification per Stage.

---

## 9. Terraform Support

### Native OpenTofu/Terraform Steps

As of the 2025-2026 timeframe, Kargo has steps for OpenTofu/Terraform, but with important availability distinctions:

- **`hcl-update`**: Update attribute values in HCL files (for modifying Terraform variable files) — **Open source**
- **`tf-plan`**: Execute an OpenTofu/Terraform plan against a configuration directory — **Platform only (v1.9+)**
- **`tf-apply`**: Apply an OpenTofu/Terraform configuration or saved plan — **Platform only (v1.9+)**
- **`tf-output`**: Retrieve output values from OpenTofu/Terraform state — **Platform only (v1.9+)**

This was highlighted in Akuity's AWS re:Invent 2025 announcements as a major expansion: "now also supporting not just Kubernetes — we're also supporting Terraform, VMs, and serverless."

### Modeling Terraform in the Kargo Pipeline

The pattern for Terraform promotion follows the same model as Kubernetes:

1. A **Warehouse** subscribes to a Git repository (the Terraform modules/configurations repo) and produces Freight from new commits
2. A **Stage** clones the repo, uses `hcl-update` to update variable files (e.g., `terraform.tfvars`) with environment-specific values, and commits
3. A separate Terraform runner (Atlantis, Terraform Cloud, Spacelift) handles the actual plan/apply via its existing PR workflow. This is the recommended pattern for OSS Kargo users since `tf-plan`/`tf-apply` are Platform only.

Example pattern for Terraform promotion (OSS — Git-only, no tf-plan/tf-apply):

```yaml
steps:
- uses: git-clone
  config:
    repoURL: https://github.com/my-org/terraform-configs.git
    checkout:
    - commit: ${{ commitFrom("https://github.com/my-org/terraform-configs.git").ID }}
      path: ./src
    - branch: environment/${{ ctx.stage }}
      create: true
      path: ./out
- uses: git-clear
  config:
    path: ./out
- uses: copy
  config:
    inPath: ./src
    outPath: ./out
- uses: hcl-update
  config:
    path: ./out/environments/${{ ctx.stage }}/terraform.tfvars
    updates:
    - key: cluster_version
      value: ${{ imageFrom("k8s-version-tracker").Tag }}
- uses: git-commit
  config:
    path: ./out
- uses: git-push
  config:
    path: ./out
# Atlantis or Terraform Cloud picks up the change via PR automation
# and handles plan/apply externally
```

### Pulumi Integration

A blog post from Pulumi documents an integration pattern where the Pulumi Kubernetes Operator (PKO) manages Pulumi stacks as Kubernetes resources, and Kargo orchestrates promotion by updating `Stack` CRDs. This is another valid pattern for teams using Pulumi instead of Terraform.

---

## 10. Observability & Dashboard

### Kargo UI

Kargo ships with a built-in web dashboard providing:

- **Pipeline DAG View**: Visual representation of the entire promotion pipeline as a graph, with color-coded Stages showing current health (Healthy, Degraded, Progressing, Unknown)
- **Freight Timeline**: Shows every piece of Freight with color-coding indicating which Stages it is active in
- **Stage Detail View**: Shows the history of Promotions into a Stage, verification results and logs, and current health indicators
- **Promotion Actions**: Manual promotion via drag-and-drop (drag Freight from timeline to Stage), one-click abort for running Promotions, and promotion workflow composition without writing YAML
- **Real-Time Updates**: No polling required — the UI reflects live status

### What "Version Deployed Where" Looks Like

The Kargo dashboard directly answers "what version is deployed where" — you can see at a glance which Freight (bundle of artifact versions) is currently promoted to each Stage. Each Stage shows its current Freight, when it was promoted, and its verification status.

### Known UI Issues

- **UI crash on projects with multiple stages or multiple image subscriptions** (Issue #5267, fixed in later patch)
- **Drag-and-drop promotion does not work with Control Flow Stages** (Issue #5285, targeted for v1.10)
- **RBAC claims annotation format not displaying correctly** after UI edit (Issue #5264, priority/urgent)

---

## 11. Maturity & Community

### Version History and Current Status

| Version | Date | Significance |
|---------|------|-------------|
| v0.1 | ~2023 | Initial public release |
| v1.0.0 | October 2024 | **GA release**; pivot to flexible PromotionSteps complete |
| v1.1.0 | ~Nov 2024 | `http` step; expression system |
| v1.2.0 | ~Jan 2025 | `PromotionTask`/`ClusterPromotionTask`; soak times |
| v1.3.0 | March 2025 | Conditional steps (`if`); Gitea support |
| v1.4.0 | April 2025 | Annotations, actor metadata, log access improvements |
| v1.5.0 | June 2025 | `ProjectConfig`; `always()`/`failure()` functions; UI overhaul; Bitbucket |
| v1.6.0 | ~July 2025 | Webhook-triggered Warehouse discovery |
| v1.7.0-v1.8.0 | ~2025 | UI enhancements, webhook receiver improvements |
| v1.9.0 | ~Late 2025 | New RESTful API, user-generated API tokens, warehouse caching |
| v1.10.x | April 2026 | Quality-of-life improvements, expanded promotion steps, partial UI migration to REST API |

**Current version**: v1.10.2 (April 22, 2026)

Release cadence: approximately **one minor release every six weeks**, with two to three major features per release.

### Community Health

- **3.2k GitHub stars**, 363 forks
- **3.5+ million downloads** (as reported by Akuity)
- Active **Discord** community
- Known enterprise adopters: Deutsche Telekom, JumpCloud, Cisco ThousandEyes
- **60% ArgoCD adoption** in CNCF survey means the potential Kargo addressable base is enormous
- Akuity provides commercial support and a managed platform offering

### Known Limitations and Open Issues

1. **No StageSet resource**: Managing many similar Stages (e.g., 10+ regions) requires manual YAML generation or Helm templating. No templated multi-Stage resource exists yet.

2. **Single Stage per ArgoCD Application annotation**: The `kargo.akuity.io/authorized-stage` annotation only supports one Stage per Application. Workarounds exist but are not officially documented (Issue #5706).

3. **GKE Workload Identity Federation for sharded controllers**: Cross-cluster auth requires manual RoleBinding creation in every Project namespace (Issue #5646). This is directly relevant for GCP deployments.

4. **`git-open-pr` fails with no changes**: If a Stage tries to open a PR but there are nothing to change (e.g., same version already deployed), the step fails instead of no-oping (Issue #5226, targeted for v1.10).

5. **Control Flow Stage drag-and-drop**: UI promotion via drag-and-drop doesn't work with Control Flow Stages (Issue #5285).

6. **Verification cannot be skipped post-promotion**: Manual approval of Freight skips upstream requirements, but the target Stage's own verification always runs. There is no way to suppress it for individual Freight.

7. **`custom-steps` is Akuity Platform only**: The most flexible extension point (running arbitrary containers) is not available in the open-source self-hosted version as of v1.10.

8. **Concurrent git-push retry inconsistency**: When multiple Stages push to the same branch concurrently, the built-in retry/rebase logic has known failure modes (Issue #5286).

9. **Terraform steps maturity**: The `tf-plan`/`tf-apply` steps are newer additions; production experience is still accumulating.

---

## 12. Comparison with Alternatives

### Kargo vs. Argo Rollouts

| Dimension | Kargo | Argo Rollouts |
|-----------|-------|---------------|
| Scope | Multi-environment promotion orchestration | Progressive delivery *within a single cluster* |
| Problem solved | "How do I move this artifact from int to stage to prod?" | "How do I deploy a new version canary within my prod cluster?" |
| Abstraction | Stages, Freight, Warehouses | Rollout (replaces Deployment), AnalysisRun |
| Traffic splitting | No | Yes (blue/green, canary with weight) |
| ArgoCD integration | First-class (`argocd-update` step) | Tight (ArgoCD tracks Rollout health) |
| Multi-cluster | Yes (core design goal) | No (single cluster controller) |
| Complementarity | They are **complementary**, not competing. Use Argo Rollouts for in-cluster canary within a Stage, and Kargo to promote across Stages. | Same |

These two tools work at different layers and are frequently deployed together. Kargo promotes Freight from int to staging to prod; Argo Rollouts manages the canary within prod.

### Kargo vs. FluxCD + Flagger

| Dimension | Kargo | FluxCD + Flagger |
|-----------|-------|------------------|
| GitOps engine | Works with ArgoCD (and potentially Flux) | Works with FluxCD (and potentially ArgoCD) |
| Promotion orchestration | Native multi-stage promotion pipeline | No equivalent — Flagger does in-cluster canary only |
| In-cluster progressive delivery | Not in scope | Yes (Flagger does canary/blue-green within cluster) |
| Multi-environment | Yes (core feature) | No native cross-environment promotion |
| Helm/Kustomize | Both natively supported | Both supported via Flux HelmRelease/Kustomization |
| Service mesh integration | Not required | Optional but powerful (Istio, Linkerd, NGINX) |

If your team uses FluxCD instead of ArgoCD, Kargo's ArgoCD dependency is a blocker (though the Kargo team has discussed Flux support). For teams on ArgoCD, Kargo is a natural fit.

### Kargo vs. ArgoCD ApplicationSet RollingSync (Progressive Sync)

| Dimension | ArgoCD ApplicationSet RollingSync | Kargo |
|-----------|----------------------------------|-------|
| Maturity | Beta | GA (v1.0+) |
| Artifact tracking | None — tracks OutOfSync state | Native — tracks images, Git commits, Helm charts as Freight |
| Promotion gates | Health-based only | Health + verification (AnalysisTemplates) + soak times + manual approval |
| Pipeline model | Linear steps in ApplicationSet spec | DAG of Stages with fan-out and fan-in |
| Reusability | Strategy must be inlined per ApplicationSet | `ClusterPromotionTask` shared across all Projects |
| Observability | ArgoCD UI only | Dedicated pipeline dashboard |
| Manual approval | No — only health-gate exists | Yes — manual approval and manual promotion |
| Git commits | No — only triggers sync | Yes — commits to Git as part of promotion |
| Installation | No extra install (built into ArgoCD) | Separate controller installation required |

RollingSync is appropriate for "roll out this ApplicationSet template change across N clusters in order." Kargo is appropriate for "promote this version of my application from integration → staging → production with verification gates."

### Kargo vs. Custom Pipelines (Tekton, Cloud Workflows, GitHub Actions)

| Dimension | Kargo | Custom CI/CD Pipelines |
|-----------|-------|----------------------|
| Purpose-built for promotion | Yes | No — general purpose |
| GitOps-native | Yes — commits to Git are first-class | Requires custom glue |
| Observability | Unified dashboard | Scattered across CI tools |
| State management | Stateful (Freight, Promotion CRDs) | Typically stateless (pipeline runs) |
| Auditability | Full history in Kubernetes CRDs | Depends on implementation |
| Artifact bundle promotion | Native (Freight) | Manual coordination |
| ArgoCD integration | Native | Requires scripting |
| Maintenance burden | Declarative YAML + operator manages reconciliation | Bespoke scripts that accumulate technical debt |
| Scalability | Designed for many environments | Degrades without significant engineering investment |

The primary advantage of Kargo over custom pipelines is that it eliminates the class of "snowflake scripts" that tend to grow in CI systems. The promotion logic is declarative, versionable, auditable, and observable out of the box.

### What Kargo Uniquely Offers

1. **Freight as a first-class concept**: The ability to bundle multiple artifact versions (image + config + chart) into an immutable, promotable unit that travels atomically through the pipeline
2. **DAG-based pipeline with fan-out/fan-in**: Not just linear stages but a graph with parallel paths and synchronization gates
3. **Soak times**: Require an artifact to be verified for a minimum duration before promoting downstream
4. **PromotionTask/ClusterPromotionTask**: Reusable promotion logic shared across multiple projects
5. **AnalysisTemplate integration**: Leverage the full Argo Rollouts metric provider ecosystem for verification
6. **ProjectConfig for freeze**: Declarative, auditable promotion policies at the Project level
7. **PR-based workflows**: `git-open-pr` + `git-wait-for-pr` for human-in-the-loop without completely blocking
8. **ServiceNow, Jira, GitHub Actions integrations**: Native steps for enterprise change management workflows

---

## Summary Assessment for GCP-HCP

Given your architecture (3-tier GKE clusters, ArgoCD, Terraform, environment/sector/region hierarchy), here is how Kargo maps to your requirements:

| Your Requirement | Kargo Support | Notes |
|-----------------|--------------|-------|
| Promote int → stage → prod | **Native** | Core use case via Stage DAG |
| Sector-level gating (canary → main) | **Native** | Stages per sector, fan-out/fan-in |
| Bundle promotion (set of components) | **Native** | Freight bundles multiple artifacts |
| Individual component rollout | **Native** | Separate Warehouse + Stage DAG per component |
| Gating tests between steps | **Native** | AnalysisTemplates, `http` step, Kubernetes Jobs |
| Fast track / skip stages | **Supported** | Manual Freight approval, bypasses upstream only |
| Freeze rollout | **Supported** | `ProjectConfig.autoPromotionEnabled: false` |
| Terraform changes | **Partial (OSS)** | `hcl-update` (OSS) updates files in Git; `tf-plan`/`tf-apply` are **Platform only** — use Atlantis/TF Cloud for plan/apply |
| ArgoCD integration | **Native** | `argocd-update` step + annotation model |
| Multi-region scaling (10+ regions) | **Functional but manual** | No StageSet yet; use Helm to generate Stage YAML |
| GKE Workload Identity | **Issue exists** | Manual RoleBinding required per-namespace for sharded setup (#5646) |
| Rendering complex hierarchical overrides | **Partial** | Built-in steps cover common patterns; complex logic needs custom container |
| Dashboard visibility | **Yes** | Dedicated UI with pipeline DAG and Freight timeline |
| Automated without human operators | **Yes** | Auto-promotion + verification + fan-out covers fully automated flows |
| Custom promotion logic | **Workaround required** | No plugin system; use `http` step + external service, or AnalysisTemplate + Kube Job for post-promotion verification |

**Primary gaps to plan for**:
- Kargo requires generating Stage YAML at scale (Helm or scripting) until StageSet is available
- The GKE Workload Identity sharded controller issue (#5646) needs tracking or workaround (manual RoleBindings) if using distributed topology
- Your existing Python rendering script will not be directly replaced by Kargo's built-in steps without restructuring the config hierarchy; a refactor toward standard Helm values files is the path forward
- `tf-plan`/`tf-apply` are **Platform only** — the OSS pattern is: Kargo commits via `hcl-update`, Atlantis/TF Cloud handles plan/apply
- `custom-steps` (arbitrary container execution) is **Platform only** — the OSS workarounds are: `http` step calling an external service for inline logic, or AnalysisTemplate + Kube Job for post-promotion verification. If neither is sufficient, the fork path (implement Go `StepRunner` interface) is available but carries ongoing rebase cost

---

## Sources

- [Kargo Official Documentation — Core Concepts](https://docs.kargo.io/user-guide/core-concepts/)
- [Kargo Official Documentation — Promotion Steps Reference](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/)
- [Kargo Official Documentation — argocd-update Step](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/argocd-update/)
- [Kargo Official Documentation — yaml-update Step](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/yaml-update/)
- [Kargo Official Documentation — Promotion Tasks Reference](https://docs.kargo.io/user-guide/reference-docs/promotion-tasks/)
- [Kargo Official Documentation — Promotion Templates Reference](https://docs.kargo.io/user-guide/reference-docs/promotion-templates/)
- [Kargo Official Documentation — Verification](https://docs.kargo.io/user-guide/how-to-guides/verification/)
- [Kargo Official Documentation — Patterns](https://docs.kargo.io/user-guide/patterns/)
- [Kargo Official Documentation — ArgoCD Integration](https://docs.kargo.io/user-guide/how-to-guides/argo-cd-integration/)
- [Kargo Official Documentation — Working with Freight](https://docs.kargo.io/user-guide/how-to-guides/working-with-freight/)
- [Kargo Official Documentation — Analysis Templates Reference](https://docs.kargo.io/user-guide/reference-docs/analysis-templates/)
- [Kargo Official Documentation — Architecture & Topology](https://docs.kargo.io/operator-guide/architecture/)
- [Kargo Official Documentation — Roadmap](https://docs.kargo.io/roadmap/)
- [Kargo Official Documentation — FAQs](https://docs.kargo.io/faqs/)
- [Kargo Official Documentation — http Step](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/http/)
- [Kargo Official Documentation — custom-steps](https://docs.kargo.io/user-guide/reference-docs/promotion-steps/custom-steps/)
- [Kargo Release Notes — v1.0.0](https://docs.kargo.io/release-notes/v1.0.0/)
- [Kargo Release Notes — v1.2.0 (PromotionTasks)](https://docs.kargo.io/release-notes/v1.2.0/)
- [Kargo Release Notes — v1.3.0 (Conditional Steps)](https://docs.kargo.io/release-notes/v1.3.0/)
- [Kargo Release Notes — v1.5.0](https://docs.kargo.io/release-notes/v1.5.0/)
- [akuity/kargo GitHub Repository](https://github.com/akuity/kargo)
- [akuity/kargo-advanced GitHub — Advanced Kargo Example](https://github.com/akuity/kargo-advanced)
- [Announcing Kargo v1.0 GA — Akuity Blog](https://akuity.io/blog/announcing-kargo-version-1-0-now-generally-available-on-the-akuity-platform)
- [What's New in Kargo v1.4 — Akuity Blog](https://akuity.io/blog/kargo-version-1-4)
- [What's New in Kargo v1.5 — Akuity Blog](https://akuity.io/blog/what-s-new-in-kargo-v1-5)
- [What's New in Kargo v1.3 — Akuity Blog](https://akuity.io/blog/what-s-new-in-kargo-v1-3-smarter-gitops-with-conditional-steps-advanced-verification)
- [What is Kargo? — Akuity](https://akuity.io/what-is-kargo)
- [Akuity Product Updates Sep 2025–Feb 2026 (Terraform Support)](https://akuity.io/blog/akuity-product-updates-sep-2025-feb-2026)
- [Promotion Steps Reference v1.1 Docs](https://release-1-1.docs.kargo.io/references/promotion-steps/)
- [Continuous Promotion on Kubernetes with GitOps — Piotr Minkowski](https://piotrminkowski.com/2025/01/14/continuous-promotion-on-kubernetes-with-gitops/)
- [Implementing a Modular Kargo Promotion Workflow — Medium/JosephCheng](https://medium.com/@zxc0905fghasd/implementing-a-modular-kargo-promotion-workflow-extracting-promotiontask-from-stage-for-long-term-1ed7dcb51b22)
- [Change Management with Pulumi Kubernetes Operator and Kargo — Pulumi Blog](https://www.pulumi.com/blog/pulumi-kubernetes-operator-and-kargo/)
- [From Commit to Production — FreeCodeCamp](https://www.freecodecamp.org/news/from-commit-to-production-hands-on-gitops-promotion-with-github-actions-argo-cd-helm-and-kargo/)
- [Introduction to Kargo — Burrell Technology Services](https://burrell.tech/blog/kargo/)
- [ArgoCD ApplicationSet Progressive Syncs Docs](https://argo-cd.readthedocs.io/en/latest/operator-manual/applicationset/Progressive-Syncs/)
- [GitHub Issue #5646 — GKE Workload Identity for sharded controllers](https://github.com/akuity/kargo/issues/5646)
- [GitHub Issue #5706 — Allow ArgoCD Application to be synced by multiple stages](https://github.com/akuity/kargo/issues/5706)
- [GitHub Issue #5226 — git-open-pr fails with no changes](https://github.com/akuity/kargo/issues/5226)
- [GitHub Issue #5285 — Drag & drop with Control Flow Stages](https://github.com/akuity/kargo/issues/5285)
- [GitHub Discussion #3887 — Manual approve and verification](https://github.com/akuity/kargo/discussions/3887)
- [Kargo Quickstart — Kargo Docs](https://docs.kargo.io/quickstart/)
- [ArgoCD Adoption & Multi-Env Promotion Gap — TFiR](https://tfir.io/argocd-adoption-kargo-multi-environment-promotion/)

**Confidence Level: High** — Based on official documentation (v1.10 era), confirmed GitHub issues, official release notes, and multiple independent corroborating community sources.