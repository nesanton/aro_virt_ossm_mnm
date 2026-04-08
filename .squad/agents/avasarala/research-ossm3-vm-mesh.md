# Research: OSSM 3.x + VM Sidecar Recipe from Red Hat Docs

**Fetched:** 2026-04-08  
**Sources:**
1. https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.3/html/installing/ossm-installing-service-mesh  
2. https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/virtualization/networking#virt-adding-vm-to-service-mesh_virt-connecting-vm-to-service-mesh

---

## PART 1: OSSM 3.3 Install Recipe

### Step 1 — Install the Sail Operator (Red Hat OpenShift Service Mesh 3)

**Via OperatorHub web console:**
- Operator name: **Red Hat OpenShift Service Mesh 3 Operator**
- Install mode: **All namespaces on the cluster** (default)
- Target namespace: `openshift-operators`
- Channel: `stable` (latest) or `stable-3.3` (pinned)
- Approval: `Automatic`

**Via CLI Subscription CR** (matches what this repo uses):
```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: servicemesh-operator3
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: servicemeshoperator3
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

Verification: `oc get csv -n openshift-operators` → Status should be `Succeeded`

---

### Step 2 — Create the `istio-system` namespace and deploy Istio CR

The `Istio` CR deploys and configures the Istio control plane. API group: `sailoperator.io/v1`.

The name **must be `default`** by convention (or use `istio.io/rev=<name>` label instead of `istio-injection=enabled`).

```yaml
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
spec:
  version: v1.24-latest    # or v1.28-latest per this repo
  namespace: istio-system
  profile: default
```

Verification: `oc get istio` → `STATUS: Healthy`

---

### Step 3 — Create the `istio-cni` namespace and deploy IstioCNI CR

The `IstioCNI` CR deploys and configures the Istio CNI plugin. **Name must be `default`.**

```yaml
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata:
  name: default
spec:
  version: v1.24-latest    # or v1.28-latest per this repo
  namespace: istio-cni      # must be a separate namespace from istio-system
  profile: default
```

> **Note from docs:** The `Istio` and `IstioCNI` resources should be in **separate** projects/namespaces.
> This repo puts both in `istio-system` — that may differ from the canonical recipe.

Verification: `oc get istiocni` → `STATUS: Healthy`

---

### Step 4 — Label namespaces for mesh participation

```bash
# Label namespace for discovery AND injection (when Istio CR name is "default"):
oc label namespace <your-namespace> \
  istio-discovery=enabled \
  istio-injection=enabled

# Or, if Istio CR name is NOT "default":
oc label namespace <your-namespace> \
  istio.io/rev=<istio-resource-name>
```

For discovery selectors, also configure the `Istio` CR:
```yaml
spec:
  values:
    meshConfig:
      discoverySelectors:
        - matchLabels:
            istio-discovery: enabled
```

---

### CRDs Installed by the Operator

Sail Operator CRDs (`sailoperator.io` API group):
- `Istio`
- `IstioRevision`
- `IstioCNI`
- `ZTunnel` (ambient mode only)

Istio CRDs (`istio.io` API groups — `networking.istio.io`, `security.istio.io`):
- `AuthorizationPolicy`, `DestinationRule`, `VirtualService`, etc.

---

### Update Strategies

Two strategies for `spec.updateStrategy`:
- `InPlace` (default) — updates in place
- `RevisionBased` — creates new revision, shifts traffic; docs **recommend `InPlace` for ambient mode**

---

### Prerequisites ⚠️

- OCP 4.18 or later (for OSSM 3.3.1 control plane)
- ARO 4 is explicitly listed as supported
- Do **not** run OSSM 3 and OSSM 2 on the same cluster unless specifically configured

---

## PART 2: Connecting a VM to a Service Mesh (OCP 4.20 Virt Docs, Section 10.13)

### Key Section: Adding a virtual machine to a service mesh

Source: Section 10.13 of OCP 4.20 Virtualization Networking

**Mechanism:** Automatic sidecar injection via annotation on the VirtualMachine's pod template.

---

### Exact Annotation Required

Place this on `spec.template.metadata.annotations`:

```yaml
sidecar.istio.io/inject: "true"
```

---

### Required VM Networking Mode

The VM **must** use **masquerade mode** on the **default pod network** (not bridge, not SR-IOV):

```yaml
spec:
  template:
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
```

---

### Exact VM manifest pattern (from docs):

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  labels:
    kubevirt.io/vm: vm-istio
  name: vm-istio
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        kubevirt.io/vm: vm-istio
        app: vm-istio            # <-- service selector label
      annotations:
        sidecar.istio.io/inject: "true"    # <-- THE key annotation
    spec:
      domain:
        devices:
          interfaces:
            - name: default
              masquerade: {}    # <-- must be masquerade, not bridge
          disks:
            - disk:
                bus: virtio
              name: containerdisk
            - disk:
                bus: virtio
              name: cloudinitdisk
        resources:
          requests:
            memory: 1024M
      networks:
        - name: default
          pod: {}              # <-- must be pod network
      terminationGracePeriodSeconds: 180
      volumes:
        - containerDisk:
            image: <image>
          name: containerdisk
```

---

### Required Service to expose VM in the mesh

```yaml
apiVersion: v1
kind: Service
metadata:
  name: vm-istio
spec:
  selector:
    app: vm-istio    # <-- must match spec.template.metadata.labels.app on the VM
  ports:
    - port: 8080
      name: http
      protocol: TCP
```

---

### Port conflicts to avoid ⚠️

Do **not** use these ports (reserved by Istio sidecar proxy):
- 15000, 15001, 15006, 15008, 15020, 15021, 15090

---

## PART 3: Known Limitations and Warnings

### OSSM 3.3 explicitly does NOT support VMs

From Section 1.2 of OSSM 3.3 supported configurations docs:
> "Supported configurations: Configurations that do not integrate external services **such as virtual machines**."

This is a direct contradiction with:
- OCP 4.20 Virtualization docs (Section 10.13) which explicitly document the procedure
- The `sidecar.istio.io/inject` annotation approach being described as the way to do it

**Interpretation:** The OCP Virtualization docs describe the integration as supported from the OpenShift Virtualization side. The OSSM 3.3 supported configurations page says VMs are not in their support scope. This is a known grey area — the integration works technically but may not be covered under OSSM 3/Sail Operator's Red Hat SLA.

### Additional limitations (from OCP 4.20 Virt networking docs)

- Integration is described as working IPv4 only on the default pod network
- The VM pod must run on a pod network with masquerade binding — not with bridge, SR-IOV, or UDN-connected primary interfaces
- No explicit mention of OSSM 3 (Sail Operator) specifically — the docs just say "Service Mesh Operator" as a prerequisite. OSSM 2.x used an entirely different operator (maistra-based). 

### The `additional resources` link in Section 10.13.2 points to OSSM 3.0 install docs:
`https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.0/html/installing/ossm-installing-service-mesh`

This suggests that at the time OCP 4.20 Virt docs were written, the intent was OSSM 3.x.

---

## Summary of Canonical Steps

1. Install `servicemeshoperator3` subscription in `openshift-operators`
2. Wait for CSV `Succeeded`
3. Create namespace `istio-system`
4. Apply `Istio` CR (`sailoperator.io/v1`, name=`default`) in `istio-system`
5. Create namespace `istio-cni` (separate from `istio-system` per docs)
6. Apply `IstioCNI` CR (`sailoperator.io/v1`, name=`default`) in `istio-cni`
7. Label application namespaces: `istio-injection=enabled`
8. On each VM: set annotation `sidecar.istio.io/inject: "true"` on `spec.template.metadata.annotations`
9. Ensure VM uses `masquerade: {}` on `pod: {}` network
10. Create a Kubernetes `Service` selecting the VM's pod label
