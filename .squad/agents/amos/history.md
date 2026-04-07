# Project Context

- **Owner:** anesterov
- **Project:** ARO Modernization Demo — "From VMware VMs to Containers on ARO"
- **Stack:** ARO (OpenShift 4.x), ARO Virt (KubeVirt), OSSM (Istio), Kiali, ArgoCD, Tekton / GHA, RHEL VMs, GitHub Copilot
- **App:** modernize-monolith-workshop (Azure-Samples) — stepped branches used as baselines
- **Created:** 2026-04-02

## Learnings

- Pipeline choice (Tekton vs GHA) is undecided — check decisions.md before building. Tekton is more OpenShift-native; GHA is more GitHub-visible.
- Container image build target: containerize individual services from the workshop app, one per step
- Image registry: likely the ARO internal registry or Quay.io — TBD
- VM provisioning needs: RHEL base image (can be older version to emphasize "legacy"), cloud-init for app install, DataVolume from CDI
- Deployment scripts should fetch the right workshop step branch and apply, making each demo step reproducible
- Keep pipeline steps minimal and clearly named — this is a demo, the audience reads the pipeline
