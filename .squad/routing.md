# Work Routing

How to decide who handles what.

## Routing Table

| Work Type | Route To | Examples |
|-----------|----------|---------|
| Demo structure, scope decisions, simplicity tradeoffs | Holden | "What should step 2 of the demo be?", "is this too complex?" |
| ARO / OSSM / Kiali / KubeVirt manifests | Naomi | YAML, Helm, VirtualMachine CRs, ServiceMeshControlPlane, destination rules |
| ArgoCD Application CRs, GitOps config | Naomi | ArgoCD app, project, sync policies |
| Blue-green / canary deployment config | Naomi | VirtualService weights, DestinationRule subsets |
| VM provisioning scripts (KubeVirt / cloud-init) | Naomi | RHEL VM creation, DataVolume, cloud-init snippets |
| App deployment from modernize-monolith-workshop | Naomi + Amos | Deploying baseline steps, namespace setup |
| Container image pipelines | Amos | Tekton pipelines, GHA workflows, Dockerfile, image push |
| VM provisioning shell scripts | Amos | Bash scripts for VM setup, pre-flight checks |
| Slides, narrative, story arc | Avasarala | Slide deck structure, speaker notes, "why ARO" story |
| Video script, demo flow timing | Avasarala | Narration script, transition points, call-outs |
| Speaker notes / talking points | Avasarala | Per-slide talking points, GHCP prompt examples |
| Code review | Holden | Review PRs, architecture alignment, simplicity check |
| Scope & priorities | Holden | What to build next, what to cut, trade-offs |
| Session logging | Scribe | Automatic — never needs routing |
| Work queue monitoring | Ralph | Automatic — activated explicitly |

## Issue Routing

| Label | Action | Who |
|-------|--------|-----|
| `squad` | Triage: analyze issue, assign `squad:{member}` label | Holden |
| `squad:holden` | Pick up issue | Holden |
| `squad:naomi` | Pick up issue | Naomi |
| `squad:avasarala` | Pick up issue | Avasarala |
| `squad:amos` | Pick up issue | Amos |

## Rules

1. **Eager by default** — spawn all agents who could usefully start work, including anticipatory downstream work.
2. **Scribe always runs** after substantial work, always as `mode: "background"`. Never blocks.
3. **Quick facts → coordinator answers directly.** Don't spawn an agent for factual questions already in context.
4. **When two agents could handle it**, Naomi owns infra, Amos owns pipelines, they collaborate on deployment.
5. **"Team, ..." → fan-out.** Spawn all relevant agents in parallel as `mode: "background"`.
6. **Storytelling and technical assets are parallel.** Avasarala can draft slides/scripts while Naomi builds manifests.
