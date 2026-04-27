# Spinnaker Evaluation: Viability as a GitOps Progressive Rollout System for GCP HCP

**Evaluation Date**: April 2026
**Context**: GCP-hosted Hypershift platform on GKE, 3-tier cluster architecture, ArgoCD per-cluster with no cross-cluster network access, small team, Git-based promotion required

---

## Executive Summary

Spinnaker is **not a viable alternative to Kargo** for our use case. There are two hard blockers:

1. **Architectural incompatibility**: Spinnaker is push-based and requires direct, authenticated network access (`kubeconfig`) to every target Kubernetes cluster. Our architecture explicitly prohibits cross-cluster network access from the promotion orchestrator.
2. **Git is not the promotion medium**: Spinnaker pushes via `kubectl apply`, not Git commits. Making it write to Git requires bypassing its entire deployment engine while paying the full operational cost of 11 JVM microservices.

Beyond these blockers, Spinnaker carries an operational burden (2-3 FTE minimum) incompatible with a small team, and its commercial ecosystem has significantly degraded (Armory acquired by Harness in a fire sale, Netflix moved away internally).

---

## 1. Architecture & Deployment Model

### 1.1 Microservice Inventory

Spinnaker consists of **11 core microservices**, all required for production:

| Service | Role |
|---------|------|
| Deck | Browser-based UI |
| Gate | API gateway, auth/authz |
| Orca | Orchestration engine, pipeline execution |
| Clouddriver | Cloud provider interface — all `kubectl apply` and K8s API calls |
| Front50 | Metadata persistence (pipelines, apps, notifications) |
| Rosco | Image bakery (VM images and manifest templates) |
| Igor | CI trigger integration (Jenkins, Travis CI, GitHub Actions) |
| Echo | Event bus, notifications (Slack, email, webhooks) |
| Fiat | Authorization service, RBAC |
| Kayenta | Automated canary analysis |
| Keel | Managed Delivery reconciler (declarative delivery) |

Additionally requires: Redis, SQL database (MySQL/PostgreSQL), object storage (GCS/S3), and Halyard/Kleat for lifecycle management.

### 1.2 Resource Requirements

- Minimum: **4 CPU cores, 16 GB RAM** at rest
- At 42-region scale: **60-100+ GB RAM** across the stack
- Clouddriver scales with registered accounts — 42 regions means 42 accounts polling every 30 seconds
- Orca is the primary bottleneck under concurrent pipeline load

### 1.3 Managed Offerings

- **Armory**: Acquired by Harness (January 2024) for ~$7M against $82M raised (fire sale). Harness intends to migrate customers to its own platform. Armory as a Spinnaker vendor is effectively dead.
- **OpsMx**: The remaining commercial support vendor. Enterprise-negotiated pricing.

### 1.4 Community Health

- Governed by Continuous Delivery Foundation (CDF), not CNCF
- Latest release: 2026.0.2 (April 2026), 8-week minor release cycle
- Netflix (original author) moved away internally years ago
- Recent releases focus on security patches and bug fixes, not new features
- Project shows maintenance-mode trajectory rather than active innovation

---

## 2. Pipeline & Promotion Model

### 2.1 Pipeline Structure

Two paradigms:
- **Imperative Pipelines**: Classical model — sequence of stages configured in UI or JSON. Multi-environment promotion via pipeline chaining.
- **Managed Delivery (Keel)**: Declarative delivery config in Git. Keel reconciles desired state. Closer to GitOps conceptually, but the Kubernetes plugin is **experimental and unmaintained since ~2022**.

### 2.2 DAG Support

Genuine DAG support within a pipeline via "Depends On" stage relationships. Fan-out and fan-in work. However, modeling 42-region fan-out requires either one giant pipeline with 42 parallel branches or the RunMultiplePipelines plugin (uncertain maintenance post-Armory).

### 2.3 Manual Approval

Manual Judgment stage is first-class. Halts pipeline execution, waits for human input. Supports Slack/email/PagerDuty notifications.

### 2.4 Bundle/Artifact Promotion

Spinnaker's "artifact" is a reference to a single versioned resource (Docker image, Helm chart, Git file). Bundling multiple artifacts for atomic promotion requires custom pipeline design. The Managed Delivery model can reference multiple artifacts, but the Kubernetes plugin for this is **experimental and abandoned**.

---

## 3. Spinnaker and GitOps — The Critical Failure

### 3.1 Push-Based, Not GitOps-Native

Spinnaker's deployment model is **push-based**: Clouddriver directly calls the Kubernetes API using `kubectl apply` against each target cluster. This requires:
1. A kubeconfig file with credentials for every target cluster
2. Direct network reachability from Clouddriver to each cluster's API endpoint
3. Read/write RBAC (typically cluster-admin) on each target cluster

**Our architecture states: no direct Kubernetes API or ArgoCD API access from the promotion orchestrator to target clusters. This is an absolute architectural incompatibility.**

### 3.2 Spinnaker Does Not Write to Git

Spinnaker's Git integration is **read-only**: it reads delivery config from Git, but does not write promotion state back. The promotion mechanism is `detect trigger → kubectl apply → advance pipeline state`. Git is a source of configuration, not the medium of deployment.

To force Git-based promotion, you would need custom Webhook/Script stages that clone, update, commit, and push — bypassing Spinnaker's entire deployment engine. You'd pay the cost of 11 microservices to use it as a glorified CI trigger runner.

### 3.3 No Native ArgoCD Integration

There is no first-class Spinnaker-ArgoCD integration. The documented pattern requires cross-cluster network access to the ArgoCD API, which our architecture prohibits.

---

## 4. Terraform Support

- **Armory Terraformer plugin**: Provided native Plan/Show/Apply stages. Now owned by Harness with no Spinnaker maintenance commitment. The open-source Spinnaker project does not include Terraform natively.
- **Without plugin**: Requires Script stages, Jenkins stages, or Webhook stages calling Atlantis — all custom glue code.

---

## 5. Freeze & Fast Track

- **Freeze**: No global freeze switch. Per-pipeline disable via UI or API. For 42 regions, requires scripting. No built-in blast-radius visualization.
- **Fast Track**: No native concept. Requires duplicate low-gate pipelines, manually triggered.

---

## 6. Verification

- **Kayenta**: Automated canary analysis comparing baseline vs canary metrics. Supports Prometheus (including GCP Managed Prometheus with proxy), Datadog, New Relic.
- **BigQuery**: Not natively supported by Kayenta. Requires custom extension or Webhook workaround.
- **HTTP**: Webhook stage with polling works well.
- This is the one area where Spinnaker has a slight edge over Kargo (Kayenta's statistical canary analysis is more mature).

---

## 7. Operational Burden

- **11 JVM microservices + Redis + SQL + GCS** to operate
- **2-3 FTE minimum** to maintain at scale
- **$600,000+/year** in staffing for large organizations
- **16-32 GB RAM** recovered by teams migrating away from Spinnaker
- Configuration via Halyard/Kleat is complex and not GitOps-native
- Adding a region: create SA, generate kubeconfig, update Halyard config, restart Clouddriver

---

## 8. Requirement-by-Requirement Assessment

| Requirement | Spinnaker | Kargo | Verdict |
|-------------|-----------|-------|---------|
| Git-based promotion (write to Git) | **No** — push-based, requires direct cluster access | **Yes** — native design | **Hard blocker** |
| No cross-cluster network access | **Fails** — kubeconfig required per cluster | **Passes** — only needs Git | **Hard blocker** |
| Component + bundle promotion | Experimental K8s plugin (abandoned ~2022) | First-class Freight abstraction | Kargo wins |
| Stage DAG with fan-out/fan-in | Yes, but complex at 42 regions | Yes, native CRD-based | Kargo more elegant |
| Manual approval gating | Yes, Manual Judgment stage | Yes, Promotion approval | Tie |
| Automated sector gating | Yes, Kayenta/Webhook | Yes, AnalysisRun/Webhook | Tie |
| Fast track | No native — custom pipeline | No native — config change | Tie |
| Global freeze | No native — per-pipeline disable | Per-Stage policy + visibility | Slight Kargo advantage |
| Terraform support | Orphaned Armory plugin | Git-commit aligns with Atlantis | Kargo wins for our stack |
| ArgoCD integration | No native — workarounds only | First-class companion | Kargo wins |
| Observability/Dashboard | Mature Deck UI | Newer but growing Dashboard | Spinnaker wins |
| Verification (Prometheus, HTTP) | Kayenta + Webhook (mature) | AnalysisRun + Webhook | Spinnaker slight edge |
| Operational complexity | 11 JVM services + Redis + SQL | Single controller + CRDs | Kargo wins decisively |
| Small team suitability | No — 2-3 FTE minimum | Yes — minimal ops | Kargo wins decisively |
| Scale to 42 regions | Possible but polling-heavy | Natural, lightweight | Kargo wins |
| Active innovation | Declining — maintenance mode | Active — rapidly evolving | Kargo wins |

---

## 9. Conclusion

**Spinnaker is not viable for our use case.** The two hard blockers (push-based architecture requiring direct cluster access, and Git not being the promotion medium) are fundamental design requirements of Spinnaker that cannot be configured or plugged around without abandoning Spinnaker's core value proposition.

Even if these blockers didn't exist, the operational burden (11 microservices, 2-3 FTE) is incompatible with a small team, and the commercial ecosystem is in decline.

The only area where Spinnaker genuinely excels is **UI maturity** (Deck) and **canary analysis** (Kayenta). Neither advantage outweighs the structural incompatibilities.

---

## Sources

- [Spinnaker Microservices Overview](https://spinnaker.io/docs/reference/architecture/microservices-overview/)
- [Spinnaker Architecture](https://spinnaker.io/docs/reference/architecture/)
- [Spinnaker Kubernetes V2 Provider](https://spinnaker.io/docs/setup/install/providers/kubernetes-v2/)
- [Spinnaker Pipeline Concepts](https://spinnaker.io/docs/concepts/pipelines/)
- [Spinnaker Managed Delivery](https://spinnaker.io/docs/guides/user/managed-delivery/)
- [Spinnaker Releases — GitHub](https://github.com/spinnaker/spinnaker/releases)
- [Armory Terraform Integration](https://docs.armory.io/plugins/terraform/)
- [Harness Acquires Armory — TechCrunch](https://techcrunch.com/2024/01/11/harness-acquires-the-assets-of-continuous-deployment-service-armory/)
- [OpsMx on Harness/Armory Acquisition](https://www.opsmx.com/blog/harness-buys-armory-what-does-this-mean-for-armory-customers/)
- [GetYourGuide — Lessons Learned Migrating to ArgoCD](https://www.getyourguide.careers/posts/lessons-learned-from-migrating-to-argocd)
- [How to Migrate from Spinnaker to ArgoCD](https://oneuptime.com/blog/post/2026-02-26-argocd-migrate-spinnaker/view)
- [Spinnaker Alternatives 2026 — Northflank](https://northflank.com/blog/spinnaker-alternatives)
- [Spinnaker Component Sizing](https://spinnaker.io/docs/reference/halyard/component-sizing/)
- [Spinnaker Resource Usage — OpsMx](https://www.opsmx.com/blog/spinnaker-resource-usage-key-takeaways-from-recent-discussions-on-clouddriver-and-orca/)
- [Kayenta — GitHub](https://github.com/spinnaker/kayenta)
- [Keel — GitHub](https://github.com/spinnaker/keel)
