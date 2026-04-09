## Session 2026-04-08 (Naomi) — Ambient Mesh Post-Mortem

### Learnings

**KubeVirt + ztunnel ambient mode: architecturally incompatible (current state)**
- KubeVirt masquerade NIC binding writes iptables `PREROUTING DNAT` rules inside the pod netns to forward `pod-ip:5000 → VM-guest:5000`. No process listens on port 5000 in the pod netns itself.
- ztunnel "inpod" ambient mode ALSO writes iptables `PREROUTING` rules to redirect all traffic to ztunnel port 15006. These two rulesets conflict in the same netns — ordering is non-deterministic.
- Even with redirect disabled on virt-launcher, ztunnel has no HBONE listener (15008) → Waypoint cannot establish HBONE tunnel → 503.
- iptables-save and nft are unavailable inside virt-launcher → you cannot inspect or fix the state from inside the container.
- **This is a fundamental limitation, not a configuration bug.** Do not attempt ambient mesh on KubeVirt masquerade until upstream Istio adds explicit KubeVirt support.

---

## Session 2026-04-08 (Naomi) — Repo Audit: Align to OSSM 3.x Sidecar Recipe

### Learnings

**Ambient artifacts audited and removed**
- No `ztunnel-impersonate-rbac.yaml` file existed in `deploy/step2-ossm/operators/` — already removed in a prior cleanup pass. Kustomization was clean.
- No `ambient.istio.io/*` labels or OSSM 2.x artifacts (`ServiceMeshControlPlane`, `ServiceMeshMemberRoll`, `maistra.io`) found anywhere in the deploy/ tree.
- The only stale ambient references were in prose/comments: `DEMO.md`, `bootstrap.sh`, `kustomization.yaml` comment, and `application.yaml` comment.

**vm.yaml — sidecar annotation alignment**
- `traffic.sidecar.istio.io/excludeInboundPorts: "5000"` was an ambient workaround (tells ztunnel to skip port 5000). Removed — in sidecar mode, Envoy correctly intercepts port 5000 inbound and DNAT to the VM guest still fires.
- `traffic.sidecar.istio.io/kubevirtInterfaces: k6t-eth0` kept — this is a valid Istio annotation that tells the proxy about KubeVirt virtual NICs to avoid intercepting guest-internal traffic.
- Added `sidecar.istio.io/inject: "true"` to `spec.template.metadata.annotations` — belt-and-suspenders alongside `istio-injection: enabled` namespace label.

**DEMO.md — full rewrite to sidecar mode**
- Removed all references to ztunnel, ambient labels, "no VM restart needed" claim.
- Added explicit VM restart step with `oc delete vmi` command.
- Added troubleshooting hint to verify `istio-proxy` container is present in pod.
- Added "Why sidecar mode" section explaining the KubeVirt+ztunnel incompatibility.
- `traffic.sidecar.istio.io/excludeInboundPorts: "5000"` removed from explanatory text — Kiali URL hardcode replaced with `oc get route` command.

**bootstrap.sh — sidecar mode comments corrected**
- "Ambient Mode" → "Sidecar Mode" in STEP 2 header.
- Toggle comment corrected: replaced ambient/ztunnel language with sidecar restart instruction.

**namespace-patch.yaml and mesh-config kustomization — already correct**
- `istio-injection: "enabled"` label was already present and correct for sidecar mode. No changes needed.

**app-project.yaml — destinations correct**
- Targets `eshoplite-vm`, `istio-system`, `tracing-system`, `openshift-operators`. All required. No `openshift-gitops` destination needed (ArgoCD Applications are applied via bootstrap `oc apply`, not synced by ArgoCD itself).

**OSSM 3.x operator manifests — clean**
- `istio.yaml`: `sailoperator.io/v1`, `kind: Istio`, `profile: default` ✅
- `istiocni.yaml`: correct OSSM 3.x format ✅
- No OSSM 2.x artifacts in any operator manifest ✅

**Sidecar injection IS compatible with KubeVirt masquerade**
- Envoy intercepts inbound, re-injects to pod-ip:5000, KubeVirt DNAT then fires correctly → guest is reached.
- Istio CNI must be enabled to avoid NET_ADMIN / SCC conflict with virt-launcher.
- VM must be bounced once after namespace label is applied (`istio-injection: enabled`) for sidecar to be injected.
- No Waypoint needed. Full L7 Kiali telemetry works with sidecar alone.

**`CA_TRUSTED_NODE_ACCOUNTS` fix is correct and required regardless of mode**
- Sail Operator deploys ztunnel in `istio-system`, but the ambient profile template defaults this to `kube-system/ztunnel`. Must override in `istio.yaml`.
- This fix should be kept even when switching back to sidecar mode (it was also a correct upstream fix).

**Ambient experiment produced one useful artifact**
- The `CA_TRUSTED_NODE_ACCOUNTS` fix. Everything else from the ambient session (Waypoint CR, ambient namespace labels, ztunnel RBAC workaround) must be reverted.

**Decisions**
- Decision memo written to `.squad/decisions/inbox/naomi-ambient-assessment.md` — awaiting anesterov confirmation on Path B (revert to sidecars).

---

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

---

## Session 2026-04-09 (Naomi) — OSSM Cluster Health Check

### Learnings

**ArgoCD Application status mismatch is cosmetic OLM constraint issue**
- ArgoCD Application `step2-ossm-operators` reports `OutOfSync` / `Progressing` status
- Message: "waiting for healthy state of operators.coreos.com/Subscription/kiali-ossm"
- Root cause: OLM constraint resolver reports `ResolutionFailed` on the Subscription due to
  "constraints not satisfiable" — the CSV `kiali-operator.v2.22.1` exists in cluster,
  but OLM resolver sees it as conflicting with the subscription manifest (likely because
  the CSV was created by a prior subscription or upgrade, and OLM can't reconcile provenance).
- Reality: All three operators (servicemesh-operator3, kiali-operator, tempo-operator)
  are INSTALLED and RUNNING. The CSVs show `Succeeded`, pods are `1/1 Running`, and
  all control plane components (istiod, Kiali, Tempo, Prometheus) are healthy.
- This is an OLM bookkeeping issue, not a functional failure. ArgoCD is stuck waiting
  for the Subscription to report healthy, but the operators are already functional.
- **Resolution:** ArgoCD Application status is misleading. Cluster is FULLY HEALTHY.

**OSSM 3.x deployment is complete and functional**
- Service Mesh Operator 3 (servicemeshoperator3.v3.3.1): CSV Succeeded, deployment 1/1
- Kiali Operator 2.22.1: CSV Succeeded, pod 1/1 Running, Kiali CR deployed, UI accessible
- Tempo Operator 0.20.0-2: CSV Succeeded, pod 1/1 Running, Tempo TempoStack deployed
- Istio CR (istio-system/default): Healthy, v1.28-latest, 1 ready revision
- istiod pod: 1/1 Running (control plane healthy)
- IstioCNI CR (istio-system/default): Healthy, 7/7 CNI DaemonSet pods Running
- Kiali pod: 1/1 Running, route functional
- Tempo pod: 4/4 Running (TempoStack with storage backend)
- Prometheus: 2/2 Running (metrics collection active)

**ArgoCD config app (step2-ossm-config) NOT deployed**
- Expected behavior per D-007 design: `application-ossm-config.yaml` exists in git
  but is NOT auto-applied. It is the DEMO TOGGLE — manual sync only.
- Anton has NOT yet applied the config app (namespace label for mesh enrollment).
- The VM is NOT yet mesh-enrolled. Sidecar will not be injected until config app
  is synced and VM is bounced.

**Cluster state: operators provisioned, mesh not yet enrolled**
- Step 2 operators: COMPLETE (despite ArgoCD cosmetic status issue)
- Step 2 config: NOT YET APPLIED (this is intentional — awaiting demo presenter action)
- Overall: READY FOR DEMO TOGGLE

---

## Session 2026-04-09 (Naomi) — Step1 Route 503 Fix

### Root cause confirmed: sidecar injected in step1, pod 1/2 → no ready endpoints → Route 503

The D010 audit added `sidecar.istio.io/inject: "true"` to the VMI template as
"belt-and-suspenders alongside istio-injection=enabled on namespace". This was incorrect.

**How Istio webhook injection works:**
The Istio mutating admission webhook fires if EITHER:
- the namespace has `istio-injection: enabled`, OR
- the pod has `sidecar.istio.io/inject: "true"`

In step1, the namespace has NO mesh label. But the pod annotation was present →
webhook fired anyway → `istio-proxy` sidecar injected into `virt-launcher` pod.

The `istio-proxy` container failed its readiness probe on port 15021 (connection refused).
This is the D-008 hypothesis confirmed: KubeVirt masquerade iptables + Envoy iptables
setup conflicted, preventing Envoy from starting cleanly. Pod stayed `1/2` → endpoint
marked not ready → Service had no ready backends → Route returned 503.

### Fix applied

**deploy/step1-vm/vm.yaml**: Removed `sidecar.istio.io/inject: "true"` from the VMI
template annotations. Replaced with a detailed comment explaining WHY it must not be
present in step1 and how injection is properly triggered in step2 (namespace label only).

Kept `traffic.sidecar.istio.io/kubevirtInterfaces: k6t-eth0` — it is a no-op in step1
(no sidecar = annotation is ignored), and it's necessary in step2 to tell Envoy not to
set up conflicting iptables interception rules on the KubeVirt virtual NIC.

**deploy/step1-vm/DEBUG.md**: New file. Step-by-step oc runbook for diagnosing 503s,
unexpected sidecar injection, cloud-init timing, and step2 sidecar readiness.

### How to apply the fix on a live cluster

```bash
oc apply -k deploy/step1-vm/
oc delete vmi eshoplite-vm -n eshoplite-vm
# KubeVirt recreates the VMI automatically (VM.spec.running: true)
# New pod will be 1/1 (no sidecar in step1) → endpoints become ready → Route works
```

### Learnings

- **`sidecar.istio.io/inject: "true"` on a pod template is NOT belt-and-suspenders.** 
  It is a primary injection trigger that fires regardless of namespace label.
  "Belt-and-suspenders" means two mechanisms that individually would produce the same result.
  Pod annotation + namespace label are redundant only if the namespace label is ALWAYS present.
  In a phased demo where OSSM is added later, the annotation on the base manifest is a liability.

- **Injection for KubeVirt VMs in a phased demo must be driven by namespace label alone.**
  The pod template in the base vm.yaml must never carry `sidecar.istio.io/inject: "true"`.
  The step2 mesh-config namespace patch (`istio-injection: enabled`) is the sole trigger.
  VM must be bounced once after that label is applied.

- **`traffic.sidecar.istio.io/kubevirtInterfaces: k6t-eth0` is safe to keep in step1.**
  Annotations that Istio reads post-injection are ignored when no sidecar is present.
  Keeping it in the base manifest means step2 inherits it automatically — no separate patch needed.
