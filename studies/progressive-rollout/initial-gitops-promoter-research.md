# gitops-promoter Evaluation: Fit Assessment for GCP HCP Progressive Rollout

**Evaluation Date**: April 2026
**Context**: GCP-hosted Hypershift platform on GKE, 3-tier cluster architecture, ArgoCD per-cluster with no cross-cluster network access, small team, Git-based promotion required
**Project**: [argoproj-labs/gitops-promoter](https://github.com/argoproj-labs/gitops-promoter) — v0.27.1 (April 2025)
**Related**: [GCP-537](https://redhat.atlassian.net/browse/GCP-537) — Progressive Rollout Framework

---

## Executive Summary

gitops-promoter is a Kubernetes-native controller from the Argo ecosystem that automates environment promotion via Git branches and Pull Requests. It is architecturally elegant for simple linear pipelines (dev → staging → prod) and leverages native SCM features (PRs, commit statuses, branch protection) as the promotion medium.

However, **it does not fit the GCP HCP progressive rollout requirements**. The critical gaps are:

1. **Linear-only promotion topology** — no DAG, no fan-out/fan-in, no parallel region rollout
2. **No bundle/artifact-level tracking** — operates at git commit level only, no Freight-like abstraction
3. **No native rollback mechanism** — rollback is a new commit through the full pipeline including all soak times
4. **Pre-1.0 maturity** — v0.27.1, 2 documented production users, experimental status
5. **Hydrator dependency** — requires ArgoCD Source Hydrator (itself rapidly evolving) or a custom hydrator

These are structural limitations of the project's design philosophy, not missing features that could be added incrementally. gitops-promoter solves a different problem than what GCP HCP needs.

---

## 1. What is gitops-promoter

gitops-promoter is a Kubebuilder-based controller that automates environment promotion in GitOps workflows. It lives under the `argoproj-labs` umbrella (the Argo community's incubator for experimental projects). Its core design philosophy is "make a change and forget it": a developer pushes to a DRY branch, and the system propagates the change through all environments automatically, gated by configurable checks at each step.

The key differentiator is that **promotion happens entirely through native SCM primitives**: branches, Pull Requests, and commit statuses. There are no custom pipeline steps, no container execution, no direct cluster access. The promotion medium is Git itself, with PRs providing the audit trail and approval mechanism.

### Relationship to ArgoCD

The relationship is close but not mandatory:

- The primary integration is with **ArgoCD's Source Hydrator** (a first-class ArgoCD feature that renders DRY manifests into environment-specific branches)
- An `ArgoCDCommitStatus` controller monitors ArgoCD Application health and feeds it back as a promotion gate
- An ArgoCD UI Extension shows promotion state directly inside the ArgoCD dashboard
- gitops-promoter does not require ArgoCD — any tool fulfilling the hydrator contract works

### Branch Model

The system operates on a strict three-tier branch model:

```
DRY branch (e.g., main)
     |
     | [hydrator renders environment-specific manifests]
     v
Staging branch: environment/dev-next
     |
     | [gitops-promoter opens PR]
     v
Live branch: environment/dev
     |
     | [gates pass → next env unlocked]
     v
environment/staging-next → environment/staging → environment/prod-next → environment/prod
```

The DRY branch contains environment-agnostic configuration (Helm charts, Kustomize overlays). The hydrator transforms this into fully-rendered, environment-specific manifests pushed to `-next` staging branches. gitops-promoter opens PRs from `-next` to the live branch for each environment, and auto-merges when all gates pass.

### Design Principles

- **No modification of DRY source files**: gitops-promoter never touches original Helm charts or Kustomize files — it only manages hydrated manifest branches
- **1:1 DRY-to-hydrated commit mapping**: Every hydrated commit maps to exactly one DRY commit, enabling linear ordered promotion
- **"Release latest" model**: The system always promotes the most recent commit — there is no mechanism to hold back or skip individual commits
- **Git SCM as source of truth**: All promotion state is visible as branches and PRs in GitHub/GitLab, using native SCM UI and tooling

---

## 2. Core Concepts & CRDs

### User-Facing Resources

| CRD | Description |
|-----|-------------|
| **PromotionStrategy** | Top-level resource. Defines the ordered list of environment branches, commit status gates, and per-environment auto-merge settings. Auto-creates one ChangeTransferPolicy per environment. |
| **ChangeTransferPolicy** | Auto-created per environment. Manages the actual branch-pair transfer: opens PR from `-next` to live branch, merges when gates pass. Injects a synthetic `promoter-previous-environment` gate to enforce sequential ordering. |
| **PullRequest** | K8s-managed wrapper around SCM PR API. Tracks PR lifecycle (open/merged/closed). Uses `spec.mergeSha` to prevent race conditions. |
| **CommitStatus** | Primary gating primitive. Wrapper around SCM commit status API. Keyed by label, has `spec.phase` (pending/success/failure) for a specific SHA. Even if SCM API is unreachable, the in-cluster object is the source of truth. |

### Gate Controllers (Built-in)

| Controller | Function |
|------------|----------|
| **ArgoCDCommitStatus** | Monitors ArgoCD Application health via label selector. Produces CommitStatus with key `argocd-health`. Supports multi-cluster ArgoCD monitoring via kubeconfig secrets. |
| **TimedCommitStatus** | Soak time / bake time gating. Configurable per environment (e.g., `1h` dev, `4h` staging, `24h` prod). Sets CommitStatus to `success` only after the configured duration. |
| **WebRequestCommitStatus** | HTTP-based gating. Calls external endpoints, evaluates response via CEL expressions. Supports polling and trigger modes. Templates allow per-environment customization. |

### SCM Configuration

| CRD | Description |
|-----|-------------|
| **GitRepository** | Represents a Git repository. Supports GitHub, GitLab, Forgejo, Bitbucket Cloud, Azure DevOps. |
| **ScmProvider / ClusterScmProvider** | SCM credentials configuration. Supports GitHub App auth, tokens, etc. Cluster-scoped variant allows multi-namespace reuse. |

### Example PromotionStrategy

```yaml
apiVersion: promoter.argoproj.io/v1alpha1
kind: PromotionStrategy
metadata:
  name: my-app
spec:
  gitRepositoryRef:
    name: my-repo
  activeCommitStatuses:
  - key: argocd-health
  - key: soak-time
  proposedCommitStatuses:
  - key: ci-tests
  environments:
  - branch: environment/dev
    autoMerge: true
  - branch: environment/staging
    autoMerge: true
  - branch: environment/prod
    autoMerge: false    # manual approval via PR review
```

---

## 3. How It Maps to Our Requirements

### 3.1 Promotion Model (REQ-PM-*)

**REQ-PM-1 Environment Progression**: Supported — environments are defined as an ordered list in PromotionStrategy. Changes progress sequentially: env[0] → env[1] → env[2].

**REQ-PM-2 Sector Progression**: **Not supported.** gitops-promoter has no concept of sectors within an environment. Each environment is a single branch pair. Modeling sectors would require multiple PromotionStrategies with manual coordination between them, which defeats the automation purpose.

**REQ-PM-3 Region Fan-Out**: **Not supported.** The promotion topology is strictly linear — there is no fan-out to multiple regions in parallel. An open GitHub issue (#1364) requests parallel branch support, but it is not implemented. Each region would need to be modeled as a separate sequential environment, resulting in a flat chain: `int-e2e → int-main-region1 → int-main-region2 → ... → stage-canary → ...`. This does not scale.

**REQ-PM-4 Configurable Rollout Ordering**: Partially supported — environment ordering is configurable in the PromotionStrategy list. But no DAG topology, no fan-out/fan-in, no parallel promotion.

### 3.2 Dual Promotion Model (REQ-DP-*)

**REQ-DP-1 Component-Level Promotion**: Partially supported — separate PromotionStrategies per component are possible, each watching different paths in the repo. However, there is no artifact-level tracking (image tag, chart version). Promotion is at the git commit level only.

**REQ-DP-2 Bundle/Snapshot Promotion**: **Not supported.** gitops-promoter has no equivalent to Kargo's Freight. There is no way to bundle multiple component versions into an identifiable, promotable unit. A git commit is the only unit of promotion, and it carries whatever happens to be in the repo at that point — no explicit version manifest.

**REQ-DP-3 Bundle Identity & Traceability**: **Not supported.** There is no bundle identity abstraction. You cannot answer "which versions of which components constitute this promotion" without inspecting the git commit contents manually.

**REQ-DP-4 Model Coexistence**: Not applicable — neither model is fully supported.

### 3.3 Gating & Verification (REQ-GV-*)

**REQ-GV-1 Automated Gating Between Sectors**: Not applicable — no sector concept.

**REQ-GV-2 Manual Gating Between Environments**: Supported — `autoMerge: false` on an environment means the PR stays open until a human merges it. SCM branch protection rules (required reviewers, CODEOWNERS) add further gating.

**REQ-GV-3 Platform Health Checks**: Partially supported — `ArgoCDCommitStatus` monitors ArgoCD Application health. `WebRequestCommitStatus` can call external APIs (Prometheus HTTP API, GCP Monitoring). But no native AnalysisTemplate equivalent — no Kubernetes Job execution, no structured metric evaluation. The CEL expression in WebRequestCommitStatus is a workaround, not a first-class verification framework.

**REQ-GV-4 Version Stability Verification**: **Not supported.** gitops-promoter has no concept of version stability windows. The `TimedCommitStatus` provides soak time (a commit must be active for N hours), but there is no mechanism to verify that specific component versions were stable across a test run.

**REQ-GV-5 Test Result Storage**: Not addressed — gitops-promoter does not store test results.

### 3.4 Fast Track (REQ-FT-*)

**REQ-FT-1 Critical Fix Fast Path**: **Not natively supported.** The "release latest" model means a hotfix commit enters the same sequential pipeline as any other change. There is no way to approve a commit to skip directly to production. The only workaround is to manually merge the PR on the production live branch, bypassing gitops-promoter and potentially violating branch protection rules.

**REQ-FT-2 Fast Track Scoping**: Not applicable — no fast track mechanism exists.

### 3.5 Freeze & Halt (REQ-FH-*)

**REQ-FH-1 Freeze Rollout Progression**: Partially supported — you can set `autoMerge: false` on environments to stop auto-merging. But there is no global freeze switch, no per-component freeze, no `ProjectConfig`-style policy. Each environment must be individually reconfigured.

**REQ-FH-2 Blast Radius Visibility During Freeze**: **Not supported.** PRs in the SCM show what changes are pending, but there is no dashboard showing what is deployed where, what is queued, or what the blast radius of an issue is.

**REQ-FH-3 Automatic Halt on Verification Failure**: Partially supported — if a CommitStatus gate fails, the PR is not merged and downstream environments are blocked. But there is no proactive halt of in-flight promotions in other environments.

### 3.6 Terraform Changes (REQ-TF-*)

**REQ-TF-1 Module Versioning**: Not addressed — gitops-promoter does not interact with Terraform files.

**REQ-TF-2 Infrastructure in Promotion Pipeline**: **Not supported.** gitops-promoter operates on hydrated Kubernetes manifests. Terraform configurations are outside its scope. There is no `hcl-update` equivalent and no mechanism to promote infrastructure changes alongside application changes.

**REQ-TF-3 Multi-Environment Atlantis**: Not addressed.

### 3.7 ArgoCD Changes (REQ-AC-*)

**REQ-AC-1 Version Pinning**: Handled differently — the hydrator renders manifests with pinned versions on environment-specific branches. ArgoCD Applications track the live branch. No `targetRevision` or image tag updates via promotion steps — the hydrator does this upstream.

**REQ-AC-2 Auditable Git Commits**: Supported — every promotion produces a PR merge commit in the SCM, fully auditable and revertable.

**REQ-AC-3 Rendering Pipeline Replacement**: The hydrator model replaces render.py conceptually, but requires adopting ArgoCD Source Hydrator (itself rapidly evolving) or building a custom hydrator. This is a significant dependency.

### 3.8 Observability (REQ-OB-*)

**REQ-OB-1 Deployment Version Visibility**: Partially supported — PR state in SCM shows what is deployed (merged) vs. pending (open PR). But there is no dedicated dashboard. The ArgoCD UI Extension adds promotion state to the ArgoCD dashboard, but it is limited to ArgoCD Source Hydrator-configured apps.

**REQ-OB-2 Rollout Progress Tracking**: Limited — visible via open/merged PR status in SCM. No pipeline DAG view, no Freight timeline equivalent.

**REQ-OB-3 Test Result Dashboarding**: Not addressed.

### 3.9 Scale & Operations (REQ-SO-*)

**REQ-SO-1 Many Regions**: **Does not scale.** With linear-only topology, 42 regions become a 42-environment sequential chain. Each promotion waits for all prior environments to complete. No fan-out means rollout time grows linearly with region count.

**REQ-SO-2 Minimal Human Operators**: The controller itself is lightweight and low-maintenance. But the lack of a dashboard, the need for a custom hydrator, and the manual coordination across multiple PromotionStrategies add operational burden.

**REQ-SO-3 Self-Service Region Addition**: Adding a region means adding a new environment entry and new branches. But the linear topology means the new region extends the sequential chain, increasing total rollout time.

### 3.10 Rollback (REQ-RB-*)

**REQ-RB-1 Roll-Forward Strategy**: Supported — revert the DRY commit and let it flow through the pipeline.

**REQ-RB-2 Git Revert**: Supported — standard git revert on the DRY branch.

**REQ-RB-3 Halt on Failure**: Partially supported — failed CommitStatus blocks the PR, preventing downstream promotion. But no proactive halt of other environments.

---

## 4. Niceties

Despite the gaps, gitops-promoter has genuine strengths worth acknowledging:

### 4.1 Native SCM Integration

Promotion via real PRs is a powerful pattern. PRs provide:
- Built-in audit trail with full diff visibility
- Native approval workflows (CODEOWNERS, required reviewers)
- Integration with existing CI checks (GitHub Actions status checks gate PRs)
- Familiar UX for developers — "merge this PR to promote"

This is arguably more transparent than Kargo's CRD-based promotion, where the promotion state lives in Kubernetes objects rather than the SCM.

### 4.2 Simplicity

The system has a small surface area: 9 CRDs, 3 built-in gate controllers, no embedded step execution engine. It does one thing (branch-to-branch promotion via PRs) and does it cleanly. There is no complex step DSL, no expression language for promotion logic, no container execution. The cognitive load is low.

### 4.3 SCM Resilience

CommitStatus objects in Kubernetes serve as the source of truth, not the SCM API. If GitHub is down, the controller continues to make gating decisions based on in-cluster state. SCM API calls are best-effort status propagation, not the decision path. This is a thoughtful design.

### 4.4 Soak Time as a First-Class Concept

`TimedCommitStatus` is a clean implementation of soak time gating. It is per-environment, configurable, and independent of other gates. Kargo has soak time too (`requiredSoakTime`), but gitops-promoter's implementation as a standalone CommitStatus controller is more composable.

### 4.5 Lightweight Operator

A single controller binary with no external dependencies (no Redis, no SQL, no object storage). Compared to Spinnaker's 11 microservices or even Kargo's controller + API server, gitops-promoter is operationally minimal.

### 4.6 Security Posture

Sigstore/cosign-signed releases, OpenSSF Best Practices badge, GitHub App auth support. The project takes supply chain security seriously for its maturity level.

---

## 5. Concerns

### 5.1 Pre-1.0 Maturity

gitops-promoter is at v0.27.1 with only **2 documented production users** (Intuit, Circle). The maintainers explicitly label it as experimental. The project lives in `argoproj-labs`, not `argoproj` — it has not been promoted to a first-class Argo project. For a production HCP platform requiring high confidence in promotion tooling, this is a significant adoption risk.

**Comparison**: Kargo reached GA (v1.0) in October 2024 and is at v1.10.2 with 3.2k GitHub stars and known enterprise adopters (Deutsche Telekom, JumpCloud, Cisco ThousandEyes).

### 5.2 ArgoCD Source Hydrator Dependency

The primary integration path depends on ArgoCD's Source Hydrator, which is itself rapidly evolving with breaking changes between ArgoCD versions (v3.2 and v3.3 introduced significant changes to how hydration state is tracked). Coupling the promotion system to a moving-target ArgoCD feature adds upgrade risk.

Building a custom hydrator is possible but requires maintaining a CI pipeline that watches the DRY branch, renders manifests per environment, and pushes to staging branches — essentially building the rendering pipeline that gitops-promoter deliberately chose not to include.

### 5.3 Linear Topology is Fundamental

The linear promotion model is not a missing feature — it is a design decision. The "1:1 DRY-to-hydrated commit mapping" and "release latest" principles are load-bearing constraints that enable the system's simplicity. Adding DAG support, fan-out, or selective commit promotion would require rethinking the core architecture.

### 5.4 No Terraform Story

gitops-promoter operates exclusively on rendered Kubernetes manifests. There is no mechanism to include Terraform changes in the promotion pipeline. Our requirement (REQ-TF-2) that infrastructure and application changes flow through the same pipeline is unaddressable without a separate orchestration system for Terraform.

### 5.5 Small Maintainer Pool

Two named maintainers (@zachaller and @crenshaw-dev). While @crenshaw-dev is also an ArgoCD core maintainer (lending credibility), a two-person project carries bus factor risk. Kargo has a larger core team backed by Akuity's commercial interest.

---

## 6. Comparison with Kargo

| Dimension | gitops-promoter | Kargo | GCP HCP Fit |
|-----------|----------------|-------|-------------|
| **Promotion topology** | Linear only | DAG (fan-out, fan-in, control flow stages) | Kargo — we need fan-out to regions |
| **Bundle/artifact tracking** | Git commit only | Freight (images + Git + Helm charts) | Kargo — we need bundle identity |
| **Promotion medium** | SCM PRs | Git commits (direct push or PR) | Both work, PR model is more transparent |
| **Verification** | CommitStatus + WebRequest (CEL) | AnalysisTemplate (K8s Jobs, Prometheus, HTTP) | Kargo — richer verification ecosystem |
| **Terraform support** | None | `hcl-update` (OSS) + Atlantis integration | Kargo — we need Terraform in the pipeline |
| **Soak time** | `TimedCommitStatus` per env | `requiredSoakTime` per Stage | Both adequate |
| **Fast track** | Not supported | Manual Freight approval (bypass upstream) | Kargo — we need fast track |
| **Freeze** | Per-env `autoMerge` toggle | `ProjectConfig` with glob/regex selectors | Kargo — more granular and auditable |
| **Rollback** | New commit through full pipeline | New commit through full pipeline | Tie — both roll-forward |
| **Dashboard** | ArgoCD UI Extension (limited) | Built-in pipeline DAG + Freight timeline | Kargo — purpose-built observability |
| **Scale (42 regions)** | Linear chain = O(n) rollout time | DAG with fan-out = O(depth) rollout time | Kargo — critical for scale |
| **Operational complexity** | Single controller, no deps | Controller + API server | gitops-promoter is lighter |
| **Maturity** | v0.27.1, 444 stars, 2 prod users | v1.10.2, 3.2k stars, GA since Oct 2024 | Kargo — significantly more mature |
| **Open-source risk** | Apache 2.0, argoproj-labs | Apache 2.0, open-core (Akuity) | gitops-promoter — no enterprise features gating |
| **Extensibility** | Custom CommitStatus + WebRequest | `http` step + AnalysisTemplate + K8s Job | Both have escape hatches; Kargo's are richer |
| **ArgoCD integration** | Via Source Hydrator + CommitStatus | Via `argocd-update` step + annotations | Both work; different tradeoffs |
| **Network isolation (CON-4)** | Fully compatible — Git-only | Fully compatible — Git-only | Tie |

---

## 7. Where gitops-promoter Would Fit

gitops-promoter is well-suited for a different class of problem than GCP HCP:

- **Simple linear pipelines**: A single application deployed to dev → staging → prod with PR-based approval
- **Small cluster counts**: 3-5 environments, not 42 regions
- **Teams already using ArgoCD Source Hydrator**: The integration is tight and the DRY-to-hydrated commit model is clean
- **Organizations that value SCM-native workflows**: PRs as the promotion medium integrates naturally with existing code review practices
- **Lightweight operational requirements**: A single controller with no external dependencies is attractive for small teams

It is **not** suited for:
- Multi-region fan-out at scale
- Bundle promotion (multiple versioned artifacts as a unit)
- Dual promotion models (component-level + bundle)
- Infrastructure changes (Terraform) in the same pipeline
- Fast track / emergency bypass flows
- Production platforms requiring mature, battle-tested tooling

---

## 8. Conclusion

gitops-promoter is a thoughtfully designed tool that elegantly solves linear environment promotion using native SCM primitives. Its PR-based promotion model is more transparent and developer-friendly than Kargo's CRD-based approach. The lightweight operational footprint and clean ArgoCD integration via Source Hydrator are genuine advantages.

However, **it does not meet the GCP HCP progressive rollout requirements**. The structural limitations — linear-only topology, no bundle tracking, no Terraform support, no fast track, no DAG — are not feature gaps that could be addressed by contributions or configuration. They are consequences of deliberate design choices (1:1 commit mapping, release-latest model, SCM-as-truth) that trade expressiveness for simplicity.

For GCP HCP's needs (multi-region fan-out, bundle promotion, Terraform integration, fast track, scale to 42 regions), **Kargo remains the significantly better fit** despite its open-core trajectory. gitops-promoter could be reconsidered if the project reaches 1.0, adds DAG support, and grows its adoption base — but that would represent a fundamental evolution of the project's design philosophy.

---

## Sources

- [GitHub — argoproj-labs/gitops-promoter](https://github.com/argoproj-labs/gitops-promoter)
- [gitops-promoter Documentation (ReadTheDocs)](https://gitops-promoter.readthedocs.io/en/latest/)
- [CRD Specs — gitops-promoter](https://argo-gitops-promoter.readthedocs.io/en/latest/crd-specs/)
- [Architecture — gitops-promoter](https://argo-gitops-promoter.readthedocs.io/en/latest/architecture/)
- [Gating Promotions — gitops-promoter](https://argo-gitops-promoter.readthedocs.io/en/latest/gating-promotions/)
- [ArgoCD Commit Status Controller](https://argo-gitops-promoter.readthedocs.io/en/latest/commit-status-controllers/argocd/)
- [ArgoCD Integrations Overview](https://gitops-promoter.readthedocs.io/en/latest/argocd-integrations/)
- [Tool Comparison — gitops-promoter](https://argo-gitops-promoter.readthedocs.io/en/latest/tool-comparison/)
- [Custom Hydrator — gitops-promoter](https://argo-gitops-promoter.readthedocs.io/en/latest/custom-hydrator/)
- [Multi-Tenancy — gitops-promoter](https://gitops-promoter.readthedocs.io/en/latest/multi-tenancy/)
- [FAQs — gitops-promoter](https://gitops-promoter.readthedocs.io/en/latest/faqs/)
- [ArgoCD Source Hydrator Documentation](https://argo-cd.readthedocs.io/en/latest/user-guide/source-hydrator/)
- [ArgoCD v3.3 Source Hydrator Changes](https://dev.to/vainkop/argo-cd-33-changed-the-source-hydrator-heres-what-to-audit-before-you-upgrade-2kdj)
- [gitops-promoter releases](https://github.com/argoproj-labs/gitops-promoter/releases)
- [gitops-promoter open issues](https://github.com/argoproj-labs/gitops-promoter/issues)
- [GitHub Issue #1364 — Parallel branch support](https://github.com/argoproj-labs/gitops-promoter/issues/1364)
- [GitHub Issue #1371 — Expression cache memory leak](https://github.com/argoproj-labs/gitops-promoter/issues/1371)
- [GitHub Issue #1327 — SCM API rate limiting](https://github.com/argoproj-labs/gitops-promoter/issues/1327)
- [GitHub Issue #1336 — Monorepo per-path promotion](https://github.com/argoproj-labs/gitops-promoter/issues/1336)
