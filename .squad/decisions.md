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

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
