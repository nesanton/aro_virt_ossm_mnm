## Session 2026-04-07 (Naomi) — Round 2: setup-app.sh succeeded

### setup-app.sh — SUCCESS
- Script launched with `sudo` so RHSM status check (needs root) and `/var/log/` writes work
- Passed `RHSM_USERNAME=skip RHSM_PASSWORD=skip` (non-empty dummies) — RHSM already registered so register step skipped
- .NET 9 SDK installed via dotnet-install.sh to `/usr/local/dotnet`; symlinked to `/usr/bin/dotnet`
- Workshop repo downloaded via `curl` tarball (git not installed, RHSM repos unavailable)
- App published to `/opt/eshoplite`; systemd unit created and started
- Sentinel: `/var/log/eshoplite-setup-done` = SUCCESS

### Fixes made to setup-app.sh
1. **Must run as root (`sudo bash`)**: `subscription-manager status` without sudo prompts for password interactively → exits non-zero → script mistakenly tries to re-register
2. **No working dnf repos**: RHSM registered with SCA but account has no subscription entitlements → "no repositories available through subscriptions" → removed `dnf install git tar curl` step; curl+tar were already in image
3. **libicu missing**: dotnet crashes without globalization libs → added `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` to install verification, publish, and systemd service
4. **git clone → curl tarball**: replaced `git clone` with `curl` tarball download from GitHub (no git in image)

### App verified UP
- `systemctl status eshoplite.service`: active (running), listening on 0.0.0.0:5000
- `curl http://127.0.0.1:5000`: returns eShopLite HTML
- External route `https://eshoplite-eshoplite-vm.apps.hkw79nhv.swedencentral.aroapp.io`: returns eShopLite HTML ✅

### Learnings
- Always run setup-app.sh with `sudo` on RHEL cloud images — subscription-manager needs root
- DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 is required when libicu is not installed
- RHEL golden images on ARO Virt often lack RHSM repo entitlements — don't rely on `dnf install` for missing packages; prefer pre-bundled tools or curl downloads
- For idempotency: clear `/var/log/eshoplite-setup-done` sentinel before re-running

## Session 2026-04-07 (Naomi) — Round 3: OSSM Integration Architecture Design

### OSSM Design Direction (design only — not yet implemented)

- **OSSM 3.x (Sail Operator)** chosen over OSSM 2.x (Maistra). OSSM 2.x is on maintenance path; OSSM 3.x uses upstream Istio CRs.
- **Istio CNI is mandatory** for KubeVirt workloads on ARO: avoids `NET_ADMIN` SCC conflict between `istio-init` init-container and `virt-launcher` pod privileges.
- **Toggle design: Option A (Two ArgoCD Apps)**: `step2-ossm-operators` (always on) + `step2-ossm-config` (toggleable mid-demo). Cleanest for live demo — visual, fast, easy to explain.
- **VM sidecar injection works** for demo purposes: Envoy intercepts inbound traffic at pod boundary (Service → virt-launcher pod → VM port 5000). VM must be bounced once after namespace label is applied.
- **No Tempo/Jaeger for steps 1–2**: Kiali topology graph is sufficient for the demo story. Add Tempo only if step 3 requires distributed tracing narrative.
- **Namespace label is a separate patch**: `step1-vm/namespace.yaml` stays mesh-free. The `istio-injection: enabled` label is applied by `step2-ossm/mesh-config/` as a Kustomize strategic merge patch.
- **GitOps for OSSM is the right approach**: makes the "add mesh" moment concrete and auditable for the audience.
- **Key ARO risk**: Kiali ClusterRole scope may require `cluster-admin`; `dedicated-admin` may be insufficient. Must test.
- **Clean removal is realistic** for demo toggle purposes (config app delete removes enrollment). CRD cleanup on full teardown needs a manual script.
- Design doc written to: `.squad/decisions/inbox/naomi-ossm-design.md`

## Session 2026-04-07 (Naomi)

### SSH access confirmed
- virtctl port-forward → 2222:22 worked; `cloud-user` SSH auth confirmed via `~/.ssh/aro-demo-vm`
- `authorized_keys` contains `ssh-ed25519 ... aro-demo-vm@whoanton`

### setup-app.sh — BLOCKED: RHSM placeholder creds
- `RHSM_USERNAME` in `.env` is still `your-redhat-email@example.com` (placeholder)
- `subscription-manager register` returned 401; script exited at Step 1
- **Action needed:** anesterov must set real RHSM credentials in `.env` and re-run:
  ```
  source .env
  ssh -i ~/.ssh/aro-demo-vm -o StrictHostKeyChecking=no -p 2222 cloud-user@127.0.0.1 \
    "RHSM_USERNAME=$RHSM_USERNAME RHSM_PASSWORD=$RHSM_PASSWORD bash ~/setup-app.sh"
  ```
- VM state: no dotnet, no eshoplite service, no sentinel file

### Cloud-init cleanup done
- Removed `chpasswd` block and `ssh_pwauth: false` from `cloudinit-secret.yaml`
- Live secret (re)created in cluster with SSH key only, no password
- Change takes effect on next full VM redeploy

### Port 5000 not yet testable (app not running)

---

# Project Context

- **Owner:** anesterov
- **Project:** ARO Modernization Demo — "From VMware VMs to Containers on ARO"
- **Stack:** ARO (OpenShift 4.x), ARO Virt (KubeVirt), OSSM (Istio), Kiali, ArgoCD, Tekton / GHA, RHEL VMs, GitHub Copilot
- **App:** modernize-monolith-workshop (Azure-Samples) — stepped branches used as baselines
- **Created:** 2026-04-02

## Option A: Minimal Cloud-Init + Manual Post-Boot Script (2026-04-07)

### Decision
- Abandoned heavy cloud-init (packages + write_files + runcmd) — app was not starting reliably
- Switched to **Option A**: minimal cloud-init (SSH key + console password only), all app setup via a standalone script run by the operator after VM boot

### Changes
- `deploy/step1-vm/cloudinit-secret.yaml` — stripped to 3 directives: `ssh_authorized_keys`, `chpasswd`, `ssh_pwauth`
- `deploy/step1-vm/setup-app.sh` (NEW) — idempotent bash script that registers RHSM, installs dotnet via dotnet-install.sh, clones repo, publishes app, installs systemd unit, opens firewall port 5000
- `.env` — added `RHSM_USERNAME` / `RHSM_PASSWORD` placeholder entries
- `deploy/bootstrap.sh` — added SSH connection + setup-app.sh run instructions at end of output

### Key constraints confirmed
- RHEL 8 golden image supports Simple Content Access — `subscription-manager register` enables dnf
- dotnet-sdk-9.0 rpm naming doesn't resolve even with RHSM; use `dotnet-install.sh` (channel 9.0)
- `setup-app.sh` is safe to commit (no creds — RHSM creds passed as env vars at runtime)
- `.env` stays gitignored; real RHSM creds stay local only



### Security cleanup
- Removed plaintext `chpasswd` block (cloud-user:eshoplite123) from `cloudinit-secret.yaml` — was leaked in public git
- Removed hardcoded SSH key (`anesterov@whoanton`) from `cloudinit-secret.yaml`
- Replaced with `ssh_authorized_keys: []` placeholder; `bootstrap.sh` now injects the real key at deploy time
- Added `*.pem` to `.gitignore`

### Cloud-init improvements
- runcmd now wrapped in `(set -xe; ...) || echo "FAILED"` subshell
- All output tees to `/var/log/eshoplite-init.log`
- Sentinel file written at end: `/var/log/eshoplite-init-done` (contains "SUCCESS" or "FAILED: <exitcode>")

### Bootstrap improvements
- `bootstrap.sh` now generates `~/.ssh/aro-demo-vm` keypair if not present
- Patches `eshoplite-cloudinit` secret with real pubkey before VM boot
- Deletes VM + PVC on each run then re-applies to force clean cloud-init

### Key insight: ArgoCD vs manual secret patching
- `oc apply -k` overwrites the secret with the placeholder; the SSH patch must happen AFTER kustomize apply
- ArgoCD selfHeal=true will also try to revert the patched secret to the git version — potential conflict
- For now: bootstrap.sh patches after apply; ArgoCD sync may revert. Long-term: use ExternalSecret or a post-sync hook

### VM redeploy (2026-04-07)
- Deleted `eshoplite-vm` VM and rootdisk PVC
- Re-applied kustomize manifest; patched secret with `~/.ssh/id_ed25519.pub`
- VM in Scheduling phase at time of this note — cloud-init will run fresh on first boot
- Expect ~15 min for dnf install + dotnet publish to complete


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
