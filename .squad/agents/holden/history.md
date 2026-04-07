# Project Context

- **Owner:** anesterov
- **Project:** ARO Modernization Demo — "From VMware VMs to Containers on ARO"
- **Stack:** ARO (OpenShift 4.x), ARO Virt (KubeVirt), OSSM (Istio), Kiali, ArgoCD, Tekton / GHA, RHEL VMs, GitHub Copilot
- **App:** modernize-monolith-workshop (Azure-Samples) — stepped branches used as baselines
- **Created:** 2026-04-02

## Learnings

- Demo scope is intentionally narrow: show the PROCESS of modernization, not a complete modernized app
- Story arc: Why VMware → ARO Virt → "two worlds, one platform" → modernizing with GHCP
- We pick up existing step code from the workshop repo branches rather than doing live modernization
- Simplicity is a core constraint — Holden has authority to cut anything that doesn't earn its place
- The demo must work reliably end-to-end every time — the "hero path" is non-negotiable
- Key narrative beats: ease of tooling, GHCP-assisted steps, OSSM blue-green visible in Kiali
