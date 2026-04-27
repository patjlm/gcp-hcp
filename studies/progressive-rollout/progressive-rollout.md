# Progressive Rollout: Requirements, Constraints & Kargo Evaluation

## Table of Contents

1. [Overview](#1-overview)
2. [Current State Summary](#2-current-state-summary)
3. [Requirements](#3-requirements)
4. [Constraints](#4-constraints)
5. [Kargo Evaluation](#5-kargo-evaluation)
6. [Preliminary Solution Landscape](#6-preliminary-solution-landscape)
7. [Open Questions](#7-open-questions)
8. [References](#8-references)
9. [Appendix A: Jira Issue Update Recommendations](#appendix-a-jira-issue-update-recommendations)
10. [Appendix B: Context for Next Steps](#appendix-b-context-for-next-steps)

---

## 1. Overview

### 1.1 Problem Statement

Any change to the GCP HCP platform — whether infrastructure (Terraform) or application (ArgoCD) — must be rolled out progressively across environments and regions to minimize blast radius. Today, changes are applied directly per-environment with no automated promotion pipeline, gating tests, or sector-based progression. As we scale to many regions across stage and production, we need a framework that propagates changes safely, automatically, and with clear visibility.

Without a progressive rollout framework:

- A bad change can reach all regions simultaneously, affecting every hosted cluster
- There is no mechanism to validate a change in a subset of regions before wider rollout
- There is no way to promote a validated set of component versions as an atomic unit
- Critical fixes have no fast path — they go through the same manual process
- Freezing rollouts when issues are found is ad hoc, with no visibility into blast radius
- Manual processes will not scale with a small team managing many regions

### 1.2 Scope

This document captures **requirements and constraints** for progressive rollout. It also includes an **evaluation of Kargo** (kargo.io) as the leading candidate technology. It does not prescribe a final solution — that is for subsequent design-decision documents after team alignment.

**Related Jira**: [GCP-537](https://redhat.atlassian.net/browse/GCP-537) — Implement Progressive Rollout Framework for Cross-Environment and Cross-Region Change Propagation

### 1.3 Terminology

| Term | Definition |
|------|-----------|
| **Environment** | A deployment tier: integration, stage, production |
| **Sector** | A group of regions within an environment (e.g., `e2e`, `main`). Sectors define rollout ordering within an environment. |
| **Bundle / Snapshot** | A complete, identified set of infrastructure + component versions promoted together as an atomic unit |
| **Promotion** | The act of moving a change (or bundle) from one sector/environment to the next |
| **Fast Track** | An expedited promotion path for critical fixes (CVE, P0 incidents) |
| **Freeze** | Halting all promotions to prevent further changes from propagating |

---

## 2. Current State Summary

### 2.1 Environment & Sector Layout

| Environment | Status | Sectors | Regions |
|------------|--------|---------|---------|
| integration | Deployed | `main` (persistent), `e2e` (ephemeral/testing) | `us-central1` |
| stage | Defined in metadata, not provisioned | TBD | TBD |
| production | Defined in metadata, not provisioned | TBD | TBD |

Source: `gcp-hcp-infra/terraform/metadata/environments.yaml`

### 2.2 ArgoCD Architecture

- ArgoCD runs **in each cluster** independently — there is no cross-cluster network access
- Each cluster's ArgoCD instance syncs from Git autonomously
- A Python rendering script (`argocd/scripts/render.py`) takes source templates from `argocd/config/` and produces rendered Helm charts in `argocd/rendered/`
- The rendering supports hierarchical overrides: `template.yaml` → `{env}/override.yaml` → `{env}/{sector}/override.yaml` → `{env}/{sector}/{region}/override.yaml`
- `patch-*.yaml` files are supported in the rendering but currently unused
- The entire `argocd/` directory structure (config, rendered, scripts) **can be fully replaced** if a better approach exists
- The intent of render.py was to have a core config per component with optional overrides/patches progressing through targets. If a promotion tool can manage this progression directly, a simpler model (1 Helm chart folder per target) is acceptable.
- Some apps track `main` branch, others use `.Values.git_revision` — no formal version pinning strategy

### 2.3 Terraform Infrastructure

- Modules referenced by local path (`source = "../../../../../modules/region"`) — all configs for a given environment share the same module code at HEAD
- No module versioning — there is no way to pin a known-good module version per environment
- Atlantis handles PR-based plan/apply for integration only (`terraform/atlantis-integration.yaml`)
- Module dependency tracking via content hashes in `modules.yaml` per config
- Stage and production are not yet configured in Atlantis

### 2.4 Current Automation

- **Atlantis**: PR-based Terraform plan/apply (integration only)
- **Tekton**: Operational pipelines on global cluster (e2e environment lifecycle) — being phased out for orchestration purposes
- **No promotion pipeline** exists between environments or sectors
- **Roll-forward via git revert** is the standard rollback approach

---

## 3. Requirements

### 3.1 Promotion Model

**REQ-PM-1: Environment Progression**
Changes must progress through environments in order: integration → stage → production. No environment may be skipped under normal operation.

**REQ-PM-2: Sector Progression**
Within each environment, changes must progress through sectors in a defined order (e.g., canary/e2e → main). The ordering must be configurable per environment.

**REQ-PM-3: Region Fan-Out**
Within a sector, promotion to multiple regions may happen in parallel. All regions in a sector must pass verification before the change is eligible for the next sector or environment.

**REQ-PM-4: Configurable Rollout Ordering**
The system must support configurable rollout ordering: which sectors receive changes first, whether progression is sequential or parallel within a sector, and how cross-environment gates work.

### 3.2 Dual Promotion Model

The system must support **two coexisting promotion models**:

**REQ-DP-1: Component-Level Promotion**
Individual components or versions can be promoted independently, giving teams autonomy over their own components. This model is suited to integration and stage environments where fast iteration is critical. Teams should be able to promote a single service update without coordinating with every other component.

**REQ-DP-2: Bundle / Snapshot Promotion**
The complete validated set of infrastructure + all components can be promoted as an atomic unit. This model is suited to production sectors where consistency and safety take priority. The exact set of versions that passed validation together must be promotable together — not component-by-component.

**REQ-DP-3: Bundle Identity & Traceability**
Each bundle/snapshot must be uniquely identifiable. It must be clear at any time:
- Which versions of which components constitute a given bundle
- Which bundle is currently deployed in each environment/sector/region
- When a bundle was promoted, by whom, and with what verification outcome

**REQ-DP-4: Model Coexistence**
Both models must coexist in the system. The platform may eventually converge on one model, but the framework must support both from the start.

### 3.3 Gating & Verification

**REQ-GV-1: Automated Gating Between Sectors**
Promotion between sectors within an environment should be automated, triggered by passing verification checks. No human intervention required for routine sector-to-sector progression.

**REQ-GV-2: Manual Gating Between Environments**
Promotion between environments (e.g., integration → stage, stage → production) must require manual approval (human gate). The approval mechanism must be auditable.

**REQ-GV-3: Platform Health Checks**
Platform-level E2E health checks must validate platform state before promotion. Minimum baseline:
- All ArgoCD Applications are deployed, synced, and healthy
- No critical alerts ongoing
- Expandable to hosted cluster lifecycle tests (create, modify, delete)

**REQ-GV-4: Version Stability Verification**
A component version is eligible for promotion only if all regions in the source sector have at least one passing test run where the component version was stable (present at both start and end of the test run). Other components may change during a test run — only the considered component must be stable.

**REQ-GV-5: Test Result Storage**
Test results must be stored in a common queryable datasource across all environments, sectors, and regions. Results must include: environment, sector, region, timestamp, pass/fail, version manifest at start and end of test run.

### 3.4 Fast Track

**REQ-FT-1: Critical Fix Fast Path**
A fast track mechanism must exist for critical fixes (CVEs, P0 incidents) that bypasses normal timing/cadence but preserves essential safety checks. The fast track must be faster than normal promotion, not just the same pipeline with a "rush" label.

**REQ-FT-2: Fast Track Scoping**
The fast track path must clearly define:
- What qualifies for fast track (e.g., CVE with CVSS ≥ 7, P0 incident, security patch)
- Which gates are skipped vs. expedited vs. preserved
- What approval is required (and from whom)
- What documentation/audit trail is produced

### 3.5 Freeze & Halt

**REQ-FH-1: Freeze Rollout Progression**
The system must support freezing rollout progression — halting all new promotions from proceeding — when issues are found. The freeze must be applicable at different scopes (per-component, per-environment, or global).

**REQ-FH-2: Blast Radius Visibility During Freeze**
When a freeze is active, the system must clearly show:
- What is currently deployed in each environment/sector/region
- What changes are queued or blocked by the freeze
- What the blast radius of the issue is (which regions/environments are affected)
- What the path forward looks like (resume, rollback, or fix-and-continue)

**REQ-FH-3: Automatic Halt on Verification Failure**
The promotion pipeline must automatically halt when verification fails in any sector/region, preventing the bad change from propagating further while the team decides on next steps.

### 3.6 Terraform Changes

**REQ-TF-1: Module Versioning**
Terraform modules must be versionable so that a known-good module version can be pinned per environment, rather than always using HEAD. A change validated in integration can then be promoted to stage as a specific, known version.

**REQ-TF-2: Infrastructure in Promotion Pipeline**
Infrastructure changes (Terraform) must flow through the same progressive rollout pipeline as application changes (ArgoCD). They may be in the same bundle or in separate bundles, but must use the same environment/sector progression and gating model.

**REQ-TF-3: Multi-Environment Atlantis**
Atlantis configuration must be extended to support stage and production environments (currently integration-only).

### 3.7 ArgoCD Changes

**REQ-AC-1: Version Pinning**
ArgoCD applications must support pinning `targetRevision`, image tags, and chart versions per environment/sector/region. The pinning mechanism must be part of the promotion pipeline (not manual edits).

**REQ-AC-2: Auditable Git Commits**
Every promotion must produce an auditable git commit showing exactly what changed, when, and why. The commit must be revertable.

**REQ-AC-3: Rendering Pipeline Replacement**
The current `render.py` process can be fully replaced. A model where each target has its own Helm chart/values folder, with the promotion tool applying version updates directly, is acceptable and potentially simpler. The key requirement is that changes progress through targets in the defined rollout order.

### 3.8 Observability

**REQ-OB-1: Deployment Version Visibility**
It must be clear at all times what version of each component is deployed in each environment/sector/region. This must be queryable and dashboardable.

**REQ-OB-2: Rollout Progress Tracking**
The system must show rollout progress: where a change (or bundle) is in the promotion pipeline, what has passed verification, what is pending, what is blocked.

**REQ-OB-3: Test Result Dashboarding**
Test results, platform health, and promotion readiness must be viewable in a dashboard (Grafana, Looker Studio, or equivalent).

### 3.9 Scale & Operations

**REQ-SO-1: Many Regions**
The system must scale to many regions (GCP has 42 regions) without requiring per-region manual intervention for routine promotions.

**REQ-SO-2: Minimal Human Operators**
The team is small. The solution must be low-maintenance, with automation handling routine promotion. Humans intervene only for: environment-level approvals, failure investigation, and fast track decisions.

**REQ-SO-3: Self-Service Region Addition**
Adding new regions or sectors should be a low-friction operation that integrates naturally with the rollout framework — add config, add to rollout ordering, done.

### 3.10 Rollback

**REQ-RB-1: Roll-Forward Strategy**
The primary rollback strategy is roll-forward: revert the bad change in git and let the corrected state propagate through the promotion pipeline.

**REQ-RB-2: Git Revert**
Rollback via git revert must be straightforward and well-documented. A reverted change should be treated as a new change flowing through the pipeline.

**REQ-RB-3: Halt on Failure**
The pipeline must halt on verification failure, preventing further propagation of a bad change while the team decides next steps (fix forward, revert, or investigate).

---

## 4. Constraints

### 4.1 Technology Stack

- **CON-1**: Must work with existing ArgoCD + Terraform stack
- **CON-2**: Must integrate with GKE Fleet / Connect Gateway architecture
- **CON-3**: Must run on existing GKE clusters (global / region / management-cluster hierarchy)

### 4.2 Network Isolation

- **CON-4**: ArgoCD instances run per-cluster with **no cross-cluster network access**. Any promotion orchestrator must operate exclusively via Git and external APIs (GCP Managed Prometheus, BigQuery, HTTP endpoints). This is a design strength — promotion engine and deployment engine are fully decoupled.

### 4.3 Flexibility

- **CON-5**: The current `render.py` process **can be fully replaced**. A simpler model (1 Helm chart folder per target, with version updates applied by the promotion tool) is acceptable.
- **CON-6**: Tekton is being phased out for orchestration — the orchestration/promotion tool is an open decision.
- **CON-7**: The metadata system (`environments.yaml`, `infra_ids.yaml`) is extensible and should be leveraged for sector/rollout definitions.

### 4.4 Operational

- **CON-8**: Team size is small — solution must be low-maintenance and not require dedicated operators
- **CON-9**: Must handle both infrastructure (Terraform) and application (ArgoCD) changes in a unified model
- **CON-10**: Integration is the only deployed environment; stage/production are not yet provisioned

### 4.5 Architectural

- **CON-11**: Regional independence architecture must be preserved — no cross-region dependencies at runtime
- **CON-12**: Atlantis is the established Terraform PR automation tool and will continue to be used

---

## 5. Kargo Evaluation

### 5.1 What is Kargo

[Kargo](https://kargo.io) is a Kubernetes-native continuous promotion platform built by Akuity, the company founded by the creators of the Argo project. It is open source (Apache 2.0), GA since October 2024, at version **v1.10.2** as of April 2026. It has 3.2k GitHub stars and 363 forks.

Kargo sits as an orchestration layer above ArgoCD. Its role is to decide **what** to put in Git and **when**, based on policies, verifications, and approvals. ArgoCD's role remains unchanged: sync manifests from Git to clusters.

Kargo does **not** require direct access to ArgoCD instances. In our architecture (per-cluster isolated ArgoCD, no cross-cluster network), Kargo would operate as a **pure Git promotion engine**: it commits version updates to Git, and each cluster's ArgoCD picks up the changes autonomously. Verification happens via external APIs. This is architecturally clean — promotion engine and deployment engine are fully decoupled.

### 5.2 Core Concepts

| Concept | Description |
|---------|-------------|
| **Project** | Unit of tenancy, maps to a Kubernetes namespace |
| **Warehouse** | Watches upstream sources (Git repos, image registries, Helm charts) for new versions. Packages discovered versions into Freight. |
| **Freight** | Immutable bundle of artifact versions (container images + Git commits + Helm charts). Travels atomically through the pipeline. Content-addressed (SHA-1 hash). |
| **Stage** | A node in the promotion DAG. Represents a deployment target (environment/sector/region). Defines what Freight it accepts and from where. |
| **PromotionTask / ClusterPromotionTask** | Reusable, parameterized sequences of promotion steps. Shared across Stages. |
| **ProjectConfig** | Project-level promotion policies, including auto-promotion settings (enable/disable per-stage). |
| **Verification** | Post-promotion health checks using AnalysisTemplate CRDs (from Argo Rollouts). Supports K8s Jobs, Prometheus, HTTP, Datadog, etc. |

### 5.3 How It Maps to Our Requirements

#### 5.3.1 Dual Promotion Model (REQ-DP-1 through REQ-DP-4)

**Component-level promotion**: Use separate Warehouses per component. Each Warehouse watches one component's image registry or Git path. When a new version appears, Kargo creates a Freight for just that component. Teams promote their component's Freight independently.

**Bundle/snapshot promotion**: Use a single Warehouse that watches multiple sources (all component images + Git config repo). Kargo bundles all discovered versions into one Freight object. The entire bundle moves atomically through the pipeline.

**Both models can coexist** in the same Kargo Project by defining multiple Warehouses and Stage DAGs.

**Bundle identity**: Each Freight has a unique content-addressed ID, a human-readable alias, and carries `status.verifiedIn` (which stages it passed), `status.currentlyIn` (where it's deployed), and `status.approvedFor` (manual approvals). Full traceability.

#### 5.3.2 Stage DAG — Environment/Sector/Region Hierarchy (REQ-PM-*)

Kargo Stages can model any hierarchy as a directed acyclic graph:

```
Warehouse
    │
    ▼
int-e2e-us-central1 ──verification──→ int-main-us-central1
                                        │
                                        ▼ (all int-main regions verified)
                                      stage-canary-us-west1
                                        │
                                        ▼ (manual approval)
                                      stage-main-us-west1 ─┐
                                      stage-main-eu-west1  ─┤──→ prod-canary-...
                                      stage-main-us-east1  ─┘
```

- **Fan-out**: One upstream Stage can feed multiple downstream Stages (parallel region rollout)
- **Fan-in**: A downstream Stage can require Freight to be verified in ALL upstream Stages before accepting it (all regions in sector must pass)
- **Soak times**: Require Freight to remain verified for a minimum duration before promoting downstream
- **Control Flow Stages**: Empty Stages that serve purely as synchronization gates (fan-in points)

#### 5.3.3 Git-Based Promotion (CON-4, REQ-AC-*)

The standard Kargo promotion flow in our architecture:

1. `git-clone` — clone the gitops repo
2. `yaml-update` or `helm-template` — update version references in the target's config
3. `git-commit` — commit with descriptive message
4. `git-push` — push to the repo
5. Each cluster's ArgoCD detects the Git change and syncs autonomously

No `argocd-update` step is used. Kargo never talks to ArgoCD directly. This is clean and matches our network isolation constraint.

For production promotions requiring human review, Kargo supports PR-based workflows: `git-open-pr` → `git-wait-for-pr` (blocks until merged).

#### 5.3.4 Verification (REQ-GV-*)

After a successful promotion, Kargo runs verification using AnalysisTemplate CRDs. Supported providers relevant to our architecture:

- **Kubernetes Jobs**: Run E2E test containers (our primary mechanism)
- **HTTP**: Query external APIs (BigQuery REST API for test results, GCP Monitoring API)
- **Prometheus**: Query GCP Managed Prometheus for platform health metrics

Verification runs after all ArgoCD Applications in the Stage reach healthy state (Kargo can track this via Git state and external health queries). If verification fails, the Freight is NOT marked as verified, and downstream Stages will not accept it — automatic halt (REQ-FH-3).

#### 5.3.5 Freeze Mechanism (REQ-FH-1, REQ-FH-2)

Kargo's `ProjectConfig` resource controls auto-promotion per-stage:

```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: ProjectConfig
metadata:
  name: my-project
spec:
  promotionPolicies:
  - stageSelector:
      name: "glob:prod-*"        # Freeze all production stages
    autoPromotionEnabled: false
  - stageSelector:
      name: "glob:*"             # Freeze everything
    autoPromotionEnabled: false
```

In-flight promotions complete; only new promotions are blocked. Re-enabling is a single field change. Stage status shows what Freight is deployed where and what is pending — visibility into blast radius.

#### 5.3.6 Fast Track (REQ-FT-*)

Kargo supports manual Freight approval: an operator can approve a specific Freight for a specific Stage, bypassing upstream verification requirements. This allows a critical fix to jump directly to production stages without waiting for the full pipeline. The target Stage's own verification still runs (safety preserved).

#### 5.3.7 Terraform Support (REQ-TF-*)

Kargo has promotion steps relevant to Terraform, but with important availability distinctions:

- `hcl-update` — update attribute values in HCL files (e.g., module version references) — **Open source**
- `yaml-update` — update Terraform variable files in YAML format — **Open source**
- `tf-plan` — run a Terraform plan — **Platform only (v1.9+)**
- `tf-apply` — apply a Terraform configuration — **Platform only (v1.9+)**
- `tf-output` — retrieve outputs from Terraform state — **Platform only (v1.9+)**

**For our architecture, the Platform-only Terraform execution steps are not needed.** Our model is: Kargo updates `.tf`/`.tfvars` files in Git via `hcl-update` or `yaml-update` (both OSS), commits, and pushes. Atlantis (or Terraform Cloud) handles the actual plan/apply via its existing PR workflow. Kargo never executes Terraform directly — it only modifies files in Git.

#### 5.3.8 Observability (REQ-OB-*)

Kargo provides a built-in web dashboard showing:

- **Pipeline DAG view**: visual representation of the promotion pipeline with color-coded stage health
- **Freight timeline**: every Freight with color-coding showing which Stages it is active in
- **Stage detail**: promotion history, verification results, current health
- **Freight status**: `verifiedIn`, `currentlyIn`, `approvedFor` — answers "what version is deployed where" at a glance

#### 5.3.9 render.py Replacement (REQ-AC-3, CON-5)

Kargo's `yaml-update` and `helm-template` steps can replace render.py. The new model would be:

- Each target (environment/sector/region) has its own Helm values file or chart directory
- Kargo's promotion steps update version references directly in the target's config
- Changes progress through targets via the Stage DAG — the promotion tool manages ordering, not the config structure
- This eliminates the pre-commit rendering step entirely

### 5.4 Concerns

#### 5.4.1 No StageSet Resource

Kargo has no built-in mechanism to generate Stage resources from a template. Each Stage is defined as an individual YAML CRD. For many regions, this means many Stage files.

**Assessment**: This is acceptable. All stages defined statically is clearer and more auditable. A Helm chart can generate the repetitive Stage YAML at install time. Adding a new region means adding a new Stage CRD file — explicit and traceable.

#### 5.4.2 Open-Core Trajectory

Kargo operates a growing open-core model. The core promotion mechanics are fully open source (Apache 2.0), but a significant number of features are gated behind the `ee.kargo.akuity.io` API group (Akuity Platform only). The enterprise code is **closed-source** — it is not in the public `akuity/kargo` repository.

| Feature | Status |
|---------|--------|
| Core promotion (Freight, Stages, Warehouses, PromotionTasks) | Open source |
| Git, Helm, Kustomize, YAML, HCL steps | Open source |
| ArgoCD integration (`argocd-update`, `argocd-wait`) | Open source |
| HTTP calls (`http`, `http-download`) | Open source |
| Verification (AnalysisTemplates, Kube Jobs, Prometheus) | Open source |
| Built-in UI dashboard | Open source |
| Terraform execution (`tf-plan`, `tf-apply`, `tf-output`) | **Platform only** |
| Notifications (`send-message`, MessageChannel, EventRouter) | **Platform only** |
| Custom steps (arbitrary container execution) | **Platform only** |
| GitHub Actions (`gha-dispatch-workflow`, `gha-wait-for-workflow`) | **Platform only** |
| Jira integration (`jira` step) | **Platform only** |
| JFrog Artifactory (`jfrog-evidence`) | **Platform only** |
| ServiceNow (5 steps) | **Platform only** |
| AI / Akuity Intelligence | **Platform only** |

Kargo uses DCO (Developer Certificate of Origin) for contributions — no CLA required, which is contributor-friendly. External PRs are accepted and merged. However, Kargo is **not a CNCF project** — Akuity has sole governance control over the roadmap.

**Assessment**: For our use case (core promotion orchestration, Git-based, with external verification), the open-source version covers our needs. Key points:

- The **`http` step** (OSS) is the primary escape hatch for external integrations: notifications via Slack webhook, CI triggers via REST API, and custom logic via HTTP proxy to an external service.
- **AnalysisTemplate + Kubernetes Job** (OSS) is the path for running arbitrary verification logic post-promotion — any containerized test or check can run as a Kube Job.
- **No plugin system exists** for promotion steps. Extending Kargo with custom inline promotion steps requires forking the Go codebase and implementing the `StepRunner` interface. The enterprise code is closed-source, so it cannot be forked — only reimplemented from scratch.
- The Terraform execution lock (`tf-plan`/`tf-apply`) is a non-issue for our architecture: we use Atlantis/Terraform Cloud for plan/apply, and Kargo only needs to update files in Git (`hcl-update`, OSS).
- Notifications can use the `http` step with Slack webhooks. GitHub Actions can be triggered via `http` step calling the GitHub REST API.
- This risk should be monitored but is not a blocker today.

#### 5.4.3 Terraform Steps Availability

The `tf-plan`, `tf-apply`, and `tf-output` steps are **Platform only** (v1.9+) — they are not available in the open-source self-hosted version. This is a non-issue for our architecture: we use Atlantis (and are considering Terraform Cloud) for plan/apply. Kargo's role is limited to updating `.tf`/`.tfvars` files in Git via `hcl-update` (OSS), and the external tool handles execution.

#### 5.4.4 Alternatives Assessment

No other tool matches Kargo's capabilities for our use case:

| Tool | Bundle Promotion | Multi-Env Pipeline | K8s Native | GitOps Native | Status |
|------|-----------------|-------------------|------------|---------------|--------|
| **Kargo** | Yes (Freight) | Yes (Stage DAG) | Yes | Yes | Active, GA |
| gitops-promoter | No (commit-level) | Linear only (no DAG) | Yes | Yes | Pre-1.0, experimental |
| Flux + Image Auto | No | Partial (scripted) | Yes | Yes | Active, CNCF |
| ArgoCD alone | No | No (sync only) | Yes | Yes | Active, CNCF |
| Spinnaker | Partial | Yes | Partial | No | Declining |
| Codefresh | Yes | Yes | Yes | Partial | Commercial |
| Gimlet | Partial | Partial | Yes | Yes | **Archived** |
| Weave GitOps | No | No | Yes | Yes | **Defunct** |

Kargo is the only purpose-built, Kubernetes-native, GitOps-first multi-environment promotion orchestrator with a first-class bundle abstraction.

### 5.5 Evaluation Status

Preliminary research is complete. **A POC is needed** to validate:

1. Git-only promotion model (no `argocd-update`) with per-cluster ArgoCD
2. Terraform file updates via `hcl-update` (OSS) + Atlantis integration pattern (Kargo commits, Atlantis applies). Note: `tf-plan`/`tf-apply` are Platform only and not needed for our workflow.
3. Config structure migration from render.py to per-target Helm values + Kargo `yaml-update`
4. Stage DAG at scale — generating and managing Stage CRDs for many regions via Helm
5. Verification via external APIs (GCP Managed Prometheus, BigQuery, HTTP)
6. Freeze/unfreeze workflow and blast radius visibility in practice

---

## 6. Preliminary Solution Landscape

This study focuses on requirements. Solution evaluation is secondary and will be covered in subsequent design-decision documents. Brief acknowledgment of candidates:

- **Kargo** — purpose-built promotion orchestrator, evaluated in Section 5 (leading candidate)
- **Spinnaker** — mature multi-cloud CD platform with rich pipeline/promotion model, but **not viable for our architecture**: push-based (requires direct cluster access), does not write to Git as promotion medium, and carries 11-microservice operational burden (2-3 FTE). Full evaluation in `initial-spinnaker-research.md`.
- **gitops-promoter** — Argo ecosystem controller (argoproj-labs) that automates environment promotion via Git branches and Pull Requests. Elegant PR-based model and lightweight operator, but **not viable for our architecture**: linear-only promotion topology (no DAG, no fan-out), no bundle/artifact tracking, no Terraform support, pre-1.0 maturity (v0.27.1, 2 production users). Solves a simpler problem than what GCP HCP requires. Full evaluation in `initial-gitops-promoter-research.md`.
- **Custom pipelines** (Cloud Workflows, Cloud Run) — more engineering effort, no built-in bundle concept, requires building promotion logic, verification, freeze, and observability from scratch
- **ArgoCD ApplicationSet RollingSync** — beta, limited to health-based gating only, no bundle concept, no manual approvals

---

## 7. Open Questions

### Requirements Clarification

- **OQ-1**: What is the expected promotion cadence? (e.g., continuous, daily, on-demand, per-sprint)
- **OQ-2**: Should bundle promotion always include both ArgoCD and Terraform changes together, or can infrastructure and application bundles be independent?
- **OQ-3**: Who approves promotions for the manual environment gates? Individual approver, team quorum, or automated with override capability?
- **OQ-4**: What is the freeze scope granularity needed? Per-component, per-environment, per-sector, or global?

### Technical

- **OQ-5**: Terraform module versioning strategy: same repo with git ref in `source` vs. dedicated module registry repo?
- **OQ-6**: How should the `e2e` sector (ephemeral, automated teardown) interact with the promotion pipeline? Is it the first stage in integration, or a parallel validation track?
- **OQ-7**: Where should the promotion orchestrator run? (global cluster is the natural choice — stable, long-lived, has Git access)
- **OQ-8**: Is BigQuery sufficient as the queryable datasource for test results, or should test results also be tracked in the promotion orchestrator's native state?

---

## 8. References

### External

- Kargo documentation: https://docs.kargo.io
- Kargo GitHub: https://github.com/akuity/kargo
- Kargo quickstart: https://docs.kargo.io/quickstart/
- Kargo promotion steps reference: https://docs.kargo.io/user-guide/reference-docs/promotion-steps/

### Internal

- [GCP-537 Epic](https://redhat.atlassian.net/browse/GCP-537) — Progressive Rollout Framework
- [GCP-580 Feature](https://redhat.atlassian.net/browse/GCP-580) — Build End-to-End Deployment Pipeline with < 24h Critical Path
- ArgoCD rendering system: `gcp-hcp-infra/argocd/README.md`
- ArgoCD sync wave standardization: `gcp-hcp/design-decisions/argocd-sync-wave-standardization.md`
- Deployment tooling swim lanes: `gcp-hcp/design-decisions/deployment-tooling-swim-lanes.md`
- GKE Fleet management: `gcp-hcp/design-decisions/gke-fleet-management.md`
- Environment metadata: `gcp-hcp-infra/terraform/metadata/environments.yaml`

---

## Appendix A: Jira Issue Update Recommendations

All updates below have been applied to the Jira issues as of 2026-04-27.

| Issue | Action | Recommended Changes |
|-------|--------|-------------------|
| [GCP-538](https://redhat.atlassian.net/browse/GCP-538) | **Update** | Add dual promotion model (component-level + bundle/snapshot) as explicit design requirement. Add freeze mechanism design: freeze/unfreeze workflow, blast radius visibility, path forward clarity. Add acceptance criteria for both. |
| [GCP-539](https://redhat.atlassian.net/browse/GCP-539) | **Update** | Add Kargo to the candidate list for evaluation. Note that Kargo is a purpose-built promotion orchestrator (not just a pipeline tool) and should be evaluated as a distinct category alongside general-purpose orchestration tools. |
| [GCP-540](https://redhat.atlassian.net/browse/GCP-540) | **Update** | Clarify that verification must work via external APIs only (no cross-cluster Kube API access due to network isolation). Add requirement for bundle-level version stability (all components in the bundle stable, not just individual). |
| [GCP-541](https://redhat.atlassian.net/browse/GCP-541) | **Update** | Add requirement for bundle-level promotion (multiple apps promoted together as a snapshot). Clarify that promotion must be Git-based only. Note that render.py can be fully replaced. |
| [GCP-542](https://redhat.atlassian.net/browse/GCP-542) | **Update** | Clarify that infrastructure changes should be part of the same promotion pipeline as application changes, using the same environment/sector progression and gating model. |
| [GCP-543](https://redhat.atlassian.net/browse/GCP-543) | **Update** | Add bundle promotion and freeze/unfreeze validation to E2E dry run scenarios. |
| [GCP-563](https://redhat.atlassian.net/browse/GCP-563) | No change | Prerequisite infrastructure, unaffected by these requirements. |
| [GCP-586](https://redhat.atlassian.net/browse/GCP-586) | **Update** | Rename to include freeze process: "Document normal, fast, and freeze promotion processes." Added full description with user story, requirements for all three process types, and acceptance criteria. |

---

## Appendix B: Context for Next Steps

This section captures design decisions and context from the initial research conversation (April 2026) that are not obvious from the requirements above. A new contributor picking up this work should read this section and the companion `initial-kargo-research.md` file.

### B.1 Key Design Decisions Made During Research

**ArgoCD network isolation is a feature, not a limitation.** ArgoCD runs per-cluster with no cross-cluster network access. Any promotion orchestrator (Kargo or otherwise) must work exclusively via Git and external APIs. This means Kargo's `argocd-update` promotion step is NOT used — instead, Kargo commits to Git and each cluster's ArgoCD syncs autonomously. This is architecturally clean: the promotion engine and deployment engine are fully decoupled. Verification uses external APIs (GCP Managed Prometheus, BigQuery, HTTP endpoints).

**render.py can be fully replaced.** The current `argocd/scripts/render.py` was designed to have a core config per component with optional overrides/patches that progress through targets. Its purpose was to manage the progression of changes across environment/sector/region hierarchies. If a promotion tool (like Kargo) can manage this progression directly by updating per-target Helm values files, the entire `argocd/` directory structure (config, rendered, scripts) can be restructured to a simpler model: one Helm chart folder per target, with the promotion tool applying version updates.

**Terraform follows the dual promotion model.** In earlier stages (integration, stage), Terraform modules are treated as an individual component that can be promoted independently — giving infrastructure teams autonomy for fast iteration. In later stages (production sectors), Terraform module versions are part of the overall bundle/snapshot promoted atomically alongside all application components.

**Static Stage definitions are preferred.** Kargo has no StageSet resource for templated multi-stage generation. All Stages are defined as individual CRDs. This is acceptable and actually clearer — a Helm chart can generate the repetitive YAML, and the result is explicit and auditable. Adding a new region means adding a new Stage CRD.

### B.2 Self-Referencing Loop Problem (from GCP-538 Comments)

An important design concern was raised in the [GCP-538 Jira comments](https://redhat.atlassian.net/browse/GCP-538): when Helm charts or Terraform modules reference the same repository by branch (e.g., `main`), a promotion commit (updating `targetRevision` or module refs) creates a new commit on the branch, which can trigger a new rollout, new tests, new eligibility, and a new promotion — creating an infinite loop.

Several approaches were discussed:
- **Fixed commit refs + bumper service**: Always reference fixed commit SHAs, never branches. A bumper service detects new commits and creates patch files.
- **Patch-based promotion**: Patch files travel through the pipeline; `template.yaml` stays untouched until the patch is fully promoted.
- **Renovate as bumper**: Use Renovate to detect new commits and bump refs, avoiding a custom bumper.

**Kargo's Warehouse model may solve this naturally**: Warehouses use `includePaths`/`excludePaths` to filter which Git changes produce new Freight. Promotion commits (which only touch per-target config files) can be excluded from Warehouse monitoring, breaking the loop. This should be validated in the POC.

### B.3 Kargo Open-Core Risk Assessment

Kargo operates an open-core model. Core promotion mechanics are fully open source (Apache 2.0), but a significant number of features are gated behind `ee.kargo.akuity.io` CRDs (Akuity Platform only). The enterprise code is **closed-source** — it is not in the public `akuity/kargo` repository.

| Feature | Status |
|---------|--------|
| Core promotion (Freight, Stages, Warehouses, PromotionTasks) | Open source |
| Git, Helm, Kustomize, YAML, HCL steps | Open source |
| ArgoCD integration (`argocd-update`, `argocd-wait`) | Open source |
| HTTP calls (`http`, `http-download`) | Open source |
| Verification (AnalysisTemplates, Kube Jobs, Prometheus) | Open source |
| Built-in UI dashboard | Open source |
| Terraform execution (`tf-plan`, `tf-apply`, `tf-output`) | **Platform only** |
| Notifications (`send-message`, MessageChannel, EventRouter) | **Platform only** |
| Custom steps (arbitrary container execution) | **Platform only** |
| GitHub Actions (`gha-dispatch-workflow`, `gha-wait-for-workflow`) | **Platform only** |
| Jira integration (`jira` step) | **Platform only** |
| JFrog Artifactory (`jfrog-evidence`) | **Platform only** |
| ServiceNow (5 steps) | **Platform only** |
| AI / Akuity Intelligence | **Platform only** |

Kargo is NOT a CNCF project — Akuity has sole governance. Apache 2.0 + DCO (no CLA) is contributor-friendly. External PRs are accepted. No community backlash found as of April 2026.

**Extensibility**: Kargo has no plugin system for promotion steps. The only way to add custom inline promotion steps is to fork the Go codebase and implement the `StepRunner` interface. Since the enterprise code is closed-source, enterprise features cannot be forked — they must be reimplemented from scratch. The OSS `http` step serves as the primary escape hatch for external integrations (Slack via webhook, CI via REST API, custom logic via HTTP proxy). Post-promotion, AnalysisTemplate + Kubernetes Job (OSS, from Argo Rollouts) can run arbitrary containerized verification logic.

For our use case (core promotion, Git-based, external verification, Atlantis for Terraform), the OSS version is sufficient. This risk should be monitored over time.

### B.4 Freight and Stage Status Fields

For observability and tooling integration, here are the key status fields on Kargo CRDs:

**Freight CRD status:**
- `status.verifiedIn` — map of Stage names where this Freight passed verification
- `status.currentlyIn` — map of Stage names where this Freight is currently deployed
- `status.approvedFor` — map of Stage names with manual approval (bypassing upstream requirements)

**Stage CRD status:**
- `status.phase` — lifecycle phase: `Steady`, `Promoting`, `Verifying`, `NotReady`
- `status.health` — aggregate health including per-ArgoCD-app health/sync status
- `status.freightHistory` — ordered list of all Freight promoted to this Stage (most recent first)
- `status.verificationHistory` — verification outcomes per Freight
- `status.lastPromotion` / `status.currentPromotion` — promotion details with timestamps and actor

All queryable via `kubectl` and visible in the Kargo UI dashboard.

### B.5 Detailed Kargo Research

The companion file `initial-kargo-research.md` contains the full technical research including:
- Complete list of all built-in promotion steps (Git, Helm, Kustomize, Terraform, ArgoCD, HTTP, Jira, ServiceNow, OCI, GitHub Actions)
- YAML examples for Warehouse, Freight, Stage, PromotionTask, and ProjectConfig resources
- Stage DAG patterns for fan-out, fan-in, and control flow stages
- PR-based promotion workflow examples
- Verification via AnalysisTemplates with Kubernetes Jobs and HTTP providers
- Detailed comparison with alternatives (Argo Rollouts, FluxCD, Spinnaker, ArgoCD ApplicationSet RollingSync)
- Full source citations
