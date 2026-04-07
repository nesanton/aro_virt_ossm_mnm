# Project Context

- **Owner:** anesterov
- **Project:** ARO Modernization Demo — "From VMware VMs to Containers on ARO"
- **Stack:** ARO (OpenShift 4.x), ARO Virt (KubeVirt), OSSM (Istio), Kiali, ArgoCD, Tekton / GHA, RHEL VMs, GitHub Copilot
- **App:** modernize-monolith-workshop (Azure-Samples) — stepped branches used as baselines
- **Created:** 2026-04-02

## Learnings

- VM phase: deploy monolith app into a RHEL VM on ARO Virt using cloud-init + DataVolume
- Container phase: extract one service at a time from the monolith into container Deployments
- OSSM is the key enabler for blue-green: traffic split between VM-hosted service and new container via VirtualService weights
- Kiali auto-discovers services if namespace is enrolled in SMCP with the right label
- ARO Virt VMs appear as pods from OSSM's perspective (via the Multus/masquerade CNI) — verify network policy compatibility
- App baseline lives at: https://github.com/Azure-Samples/modernize-monolith-workshop
- Keep manifests in a `deploy/` directory with subdirs per step: `deploy/step1-vm/`, `deploy/step2-ossm/`, `deploy/step3-container/`

## Step 1 VM + ArgoCD (2026-04-02)

### App: eShopLite.StoreCore
- The workshop baseline monolith is **eShopLite** — an ASP.NET app
- The .NET Framework 4.8 version (original baseline) is **Windows-only** and cannot run on RHEL
- We use the **module 3 StartSample** (`3-modernize-with-github-copilot/StartSample/src/eShopLite.StoreCore`)
  which is the fully migrated .NET 9 ASP.NET Core MVC monolith — still a single app, but Linux-runnable
- It uses SQLite (no external DB dependency), making it ideal for a self-contained VM demo
- Kestrel default port: **5000** (set via ASPNETCORE_URLS env var in systemd unit)

### VM Image Choice
- Using `quay.io/containerdisks/centos-stream8` (CentOS Stream 8 = RHEL 8 user-space, no pull secret needed)
- containerdisk = ephemeral root = perfect for "destroy cluster and restart" demo workflow
- Caveat: .NET 9 not in CentOS Stream 8 repos → install via `dotnet-install.sh` (Microsoft script)

### ArgoCD Setup
- AppProject: `eshoplite-demo` in `openshift-gitops` namespace
- Application: `eshoplite-step1-vm` — sources `deploy/step1-vm/` from this repo
- sync: automated, selfHeal=true, prune=true, CreateNamespace=true, ServerSideApply=true
- ServerSideApply needed because KubeVirt VM specs are large and have management fields

### cloud-init First-Boot Flow
1. Install curl/git/libicu/krb5-libs via packages directive
2. Write systemd unit to /etc/systemd/system/eshoplite.service via write_files  
3. runcmd: download dotnet-install.sh → install .NET 9 SDK → git clone → dotnet publish → systemctl enable+start
4. firewall-cmd opens port 5000 (with || true since firewalld may be inactive)

### Service / Route
- Service: ClusterIP, port 80 → targetPort 5000 (selector: app=eshoplite-vm)
- Route: edge TLS, auto-hostname, insecureEdgeTerminationPolicy=Redirect
- KubeVirt VMI pod inherits labels from spec.template.metadata.labels → Service selector works

### Bootstrap
- deploy/bootstrap.sh: applies AppProject then Application, handles optional private repo auth
- ArgoCD admin password fetched from `openshift-gitops-cluster` secret (standard GitOps operator)
- User must set GIT_REPO_URL in .env before running bootstrap

### Env vars needed in .env
- GIT_REPO_URL — this repo's GitHub URL (for ArgoCD Application + bootstrap script)
- GIT_USERNAME — GitHub username (only for private repos)
- GIT_TOKEN    — GitHub PAT (only for private repos)
- ARGOCD_NAMESPACE — defaults to openshift-gitops (usually correct for ARO)
