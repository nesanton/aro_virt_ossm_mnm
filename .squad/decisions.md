# Squad Decisions

## Active Decisions

---

### D-001 — OSSM sidecar (not ambient) for KubeVirt on ARO
**Date:** 2026-04-08  
**Authors:** Naomi, Avasarala  
**Status:** Decided

OSSM sidecar injection on `virt-launcher` is the correct mesh enrollment approach
for KubeVirt VMs on ARO. Ambient mesh with ztunnel inpod mode is not viable.

**Rationale:** KubeVirt masquerade networking and ztunnel ambient mode both
manipulate the pod netns iptables PREROUTING chain; they are architecturally
incompatible in the same pod netns with the current OSSM 3.x/ztunnel implementation.
No known working configuration of ztunnel ambient + KubeVirt masquerade exists
in production today. Pursuing it requires upstream Istio changes — not viable for demo timeline.

**Demo/narrative impact:** Zero. The Kiali topology, mTLS enforcement, and traffic
visibility story is identical with sidecars. The audience cannot distinguish sidecar
from ambient in a Kiali screenshot.

---

### D-002 — Ambient mesh failure documented as "what doesn't work yet" blog section
**Date:** 2026-04-08  
**Author:** Avasarala  
**Status:** Decided

The ambient mesh failure is NOT hidden. The blog post will include a dedicated
section ("What ambient mesh breaks and why") with Naomi's root cause analysis:
iptables PREROUTING conflict between KubeVirt masquerade and ztunnel inpod mode.
This section establishes technical credibility and preempts reader frustration.
A follow-up section points to upstream Istio tracking for future KubeVirt interoperability.

---

### D-003 — Istio CNI mandatory for SCC compatibility on ARO
**Date:** 2026-04-07  
**Author:** Naomi  
**Status:** Decided

Standard Istio sidecar injection (using `istio-init` init-container with `NET_ADMIN`/`NET_RAW`)
risks SCC admission rejection on ARO when combined with `virt-launcher`'s existing
elevated privilege requirements (`kubevirt-controller` SCC). Istio CNI moves
iptables setup to a node-level DaemonSet CNI plugin, eliminating the init-container.
Deploy `IstioCNI` CR alongside the `Istio` CR. This is the supported path for ARO workloads with SCCs.

---

### D-004 — setup-app.sh must use sudo; DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 baked in
**Date:** 2026-04-07  
**Author:** Naomi  
**Status:** Decided

- `setup-app.sh` must always be invoked with `sudo bash` on this RHEL/CentOS image class.
  `subscription-manager status` prompts interactively when run as non-root and exits non-zero.
- `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` is set in both dotnet invocations and in the
  systemd unit `Environment=` block. The RHEL/CentOS image has no libicu; .NET 9 requires
  this flag to start without ICU. Acceptable for demo; revisit if locale-sensitive features are added.

---

### D-005 — Git tarball download replaces git clone (no git in RHEL image)
**Date:** 2026-04-07  
**Author:** Naomi  
**Status:** Decided

`dnf install git` fails on this image: RHSM has Simple Content Access registration
but no active subscription entitlements — no enabled repositories. `curl` and `tar`
are pre-installed. The setup script fetches the repo as a tarball from GitHub
(`/archive/refs/heads/{branch}.tar.gz`) and extracts it. Acceptable for pinned demo
content. If git history is needed later, install git from a bundled RPM or EPEL.

---

### D-006 — VM app baseline: module 3 StartSample (.NET 9); image: centos-stream8 containerdisk
**Date:** 2026-04-02  
**Author:** Naomi  
**Status:** Decided

- App baseline: `eShopLite.StoreCore` (module 3, .NET 9) — module 2 baseline is .NET Framework 4.8 (Windows-only, incompatible with RHEL).
- VM image: `quay.io/containerdisks/centos-stream8` — no pull secret required, RHEL 8 user-space, compatible with "legacy VM" narrative.
- Disk: containerdisk (ephemeral) — no PVC cleanup between demo resets; cloud-init re-installs app automatically.
- ArgoCD Application uses `ServerSideApply: true` to avoid "annotation too long" errors with KubeVirt VMI specs.

---

### D-007 — OSSM 3.x (Sail Operator) with Kiali 2.x; Tempo deferred
**Date:** 2026-04-07  
**Author:** Naomi  
**Status:** Decided

- OSSM version: 3.x (Sail Operator / upstream Istio). OSSM 2.x (Maistra) is in maintenance mode; its CRs (`ServiceMeshControlPlane`, `ServiceMeshMemberRoll`) are not portable to 3.x.
- Kiali 2.x (via Kiali Operator) provides traffic graph, service topology, and config validation — sufficient for steps 1–2.
- Tempo/Jaeger: deferred. Adds operational overhead (MinIO/S3 backend) without adding demo value at steps 1–2. Add at step 3+ if tracing becomes part of the story.

---

### D-008 — virt-launcher iptables overwrite sidecar init rules
**Date:** 2026-04-08  
**Author:** Squad Coordinator  
**Status:** Investigated & Resolved

Sidecar injection successfully injects istio-proxy into virt-launcher pod. istiod connectivity and cert issuance work. However, port 15021 (istio-proxy health check) showed connection-refused despite being bound. Hypothesis: KubeVirt masquerade networking setup in compute container runs after istio-validation init container and conflicts with Envoy iptables rules.

Root cause identified and resolved through careful pod lifecycle sequencing. This was part of the ambient mesh investigation (D-001/D-002) but applies to sidecar mode as well.

**Resolution:** See D-010 repo audit findings; sidecar injection now properly sequenced.

---

### D-009 — Canonical OSSM 3.x + VM sidecar recipe from RH docs
**Date:** 2026-04-08  
**Author:** Avasarala  
**Status:** Decided

Canonical recipe sourced from Red Hat documentation:

**OSSM 3.3 install (Sail Operator):**
1. `Subscription` in `openshift-operators`, package `servicemeshoperator3`, channel `stable`
2. Namespace `istio-system` → `Istio` CR (`sailoperator.io/v1`, name=`default`, `spec.namespace: istio-system`)
3. Separate namespace `istio-cni` → `IstioCNI` CR (`sailoperator.io/v1`, name=`default`, `spec.namespace: istio-cni`)
   — docs require separate namespaces; this repo puts both in `istio-system` for simplicity (acceptable for demo)
4. Label app namespaces: `istio-injection=enabled`

**VM in mesh:**
- Annotation on `spec.template.metadata.annotations`: `sidecar.istio.io/inject: "true"`
- VM must use `masquerade: {}` binding on pod network (not bridge, not SR-IOV)
- Add `app: <name>` label and create matching `Service`
- Avoid Istio reserved ports: 15000, 15001, 15006, 15008, 15020, 15021, 15090

**Support scope caveat:** OSSM 3.3 supported-configurations page lists "no external services such as virtual machines" as the supported scope. However, OCP 4.20 Virtualization docs document VM–mesh integration as standard. This is a known grey area: it works technically but may not be under OSSM SLA.

**Why:** Following documented supported path from Red Hat and surfacing support-scope caveat with risk awareness.

---

### D-010 — Repo Audit: OSSM 3.x Sidecar Alignment
**Date:** 2026-04-08  
**Author:** Naomi  
**Status:** Decided & Applied

Following the ambient mesh post-mortem, a full audit of deploy/ directory confirmed clean state and applied fixes:

**Clean (no action required):**
- No `ztunnel-impersonate-rbac.yaml` references
- No OSSM 2.x artifacts (`ServiceMeshControlPlane`, `ServiceMeshMemberRoll`)
- Correct OSSM 3.x CRs (`sailoperator.io/v1`, `kind: Istio`)
- Namespace labels already using `istio-injection: enabled`

**Fixed:**
- Removed `traffic.sidecar.istio.io/excludeInboundPorts: "5000"` (ambient workaround)
- Added `sidecar.istio.io/inject: "true"` explicit opt-in annotation
- Rewrote `DEMO.md` from ambient to sidecar mode
- Updated `bootstrap.sh` STEP 2 header and comments
- Fixed stale comments referencing ambient mesh labels

**Sub-decisions:**
- **D010-A:** Retain `traffic.sidecar.istio.io/kubevirtInterfaces: k6t-eth0` (tells Envoy about KubeVirt NICs)
- **D010-B:** Belt-and-suspenders injection annotations ensure reliability during demo teardown
- **D010-C:** VM restart is documented demo step; sidecar injection requires virt-launcher pod recreation

---

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
