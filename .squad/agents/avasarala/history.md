# Project Context

- **Owner:** anesterov
- **Project:** ARO Modernization Demo — "From VMware VMs to Containers on ARO"
- **Stack:** ARO (OpenShift 4.x), ARO Virt (KubeVirt), OSSM (Istio), Kiali, ArgoCD, Tekton / GHA, RHEL VMs, GitHub Copilot
- **App:** modernize-monolith-workshop (Azure-Samples) — stepped branches used as baselines
- **Created:** 2026-04-02

## Learnings

- Story arc has three acts: (1) Why ARO Virt from VMware, (2) Two worlds on one platform, (3) Modernize with GHCP
- The audience needs to feel the EASE — not just see the steps
- GitHub Copilot prompt moments are key "aha" beats in the video — they need to be scripted carefully, not improvised
- Kiali's graph view is a visual narrative gift — use it to show traffic shifting from VM to container (blue-green in motion)
- Keep slide count ≤ 12–15. Every slide must advance the story or it's cut.
- The demo isn't "complete modernization" — it's showing the START and what it enables. That's the story.
- **2026-04-08 — Ambient mesh assessment / blog angle:**
  - Ambient vs sidecar is invisible to the demo audience — they see the same Kiali graph either way. Do not let infrastructure implementation details drive narrative decisions.
  - The ambient experiment produced valuable outputs (root cause analysis, `CA_TRUSTED_NODE_ACCOUNTS` fix) that feed directly into a stronger blog post. Failed experiments are not wasted if they produce content.
  - Path B (sidecars) preserves every visual demo beat. Path C (skip VM mesh) kills the best beat in Step 2 — the "VM becomes visible in Kiali" moment. Never plan to Path C; keep it as a live emergency fallback only.
  - Blog credibility comes from documenting what doesn't work, not just what does. "What ambient breaks and why" is the most searchable, bookmark-worthy section in a KubeVirt + OSSM post. Don't hide the failure — lead with the analysis.
  - Naomi's one-sentence root cause statement is already publication-ready. Quote it verbatim in the blog.
