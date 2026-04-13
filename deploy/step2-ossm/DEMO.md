# Step 2 — OSSM Demo Toggle

## What's deployed (always on)

The `step2-ossm-operators` ArgoCD Application installs:

- **Sail Operator** (OSSM 3.x / Istio v1.28) + `istiod` + Istio CNI DaemonSet
- **Kiali** (traffic topology UI)
- **Prometheus** (metrics backend for Kiali graph)
- **Tempo** (distributed tracing backend, in-memory)

These stay running permanently. They do not affect app traffic until the mesh is enabled.

**Kiali URL:**
```
oc get route kiali -n istio-system -o jsonpath='{.spec.host}'
```

---

## Demo flow — "before and after mesh"

### Show "before mesh" state

The app is running. The `eshoplite-vm` namespace has no `istio-injection` label. Kiali
shows nothing for `eshoplite-vm` (no enrolled workloads). Route and app work normally.

### Enable the mesh (before → after)

```bash
source .env
oc login ${ARO_API%/} -u ${ARO_ADMIN_USER} -p ${ARO_ADMIN_PASSWORD}

GIT_REPO_ORG=$(echo "$GIT_REPO_URL" | sed 's|https://github.com/||')
sed "s|YOUR_ORG/aro-ossm-ghcp.git|${GIT_REPO_ORG}|g" \
  deploy/argocd/application-ossm-config.yaml | oc apply -f -

# The app has no automated sync — trigger it manually:
oc patch application step2-ossm-config -n openshift-gitops \
  -p '{"operation":{"sync":{}}}' --type merge

# Verify the label landed:
oc get namespace eshoplite-vm --show-labels | grep istio-injection
```

Or in the **ArgoCD UI**: sync the pre-created `step2-ossm-config` application.

**Effect:** ArgoCD patches the existing `eshoplite-vm` namespace with
`istio-injection: enabled` and patches the existing `eshoplite-vm`
VirtualMachine template with the mesh annotations needed for sidecar mode.

> **⚠️ Sidecar mode requires a VM restart.** The Envoy sidecar is injected into the
> `virt-launcher` pod at pod creation time. After the namespace label lands, restart
> the VM to trigger sidecar injection:
> ```bash
> oc delete vmi eshoplite-vm -n eshoplite-vm
> # The VirtualMachine controller recreates the VMI automatically.
> oc wait vmi/eshoplite-vm -n eshoplite-vm --for=condition=Ready --timeout=120s
> ```

After ~30 seconds with the sidecar running, open Kiali — the `eshoplite` service node
will appear. For step 2 onward, use the Istio ingress gateway Route as the public
entrypoint so traffic flows through the mesh instead of the direct app Route.
Generate some traffic to populate the graph:

```bash
ROUTE=$(oc get route eshoplite-ingress -n istio-system -o jsonpath='{.spec.host}')
for i in $(seq 1 20); do
  curl -sk "https://${ROUTE}" -o /dev/null
  sleep 1
done
```

The step 1 Route in `eshoplite-vm` still exists, but it bypasses Istio and should be
treated as a debug path once the mesh is enabled.

### Disable the mesh (after → before)

```bash
sed "s|YOUR_ORG/aro-ossm-ghcp.git|${GIT_REPO_ORG}|g" \
  deploy/argocd/application-ossm-config.yaml | oc delete -f -
```

Or in the **ArgoCD UI**: delete the `step2-ossm-config` application (with cascade prune).

**Effect:** ArgoCD runs a delete hook that removes the `istio-injection` label from
`eshoplite-vm` and removes the mesh annotations from the existing VirtualMachine.
The namespace and VM are not deleted. Existing sidecar containers remain in the
running VMI until the next VM restart. App continues to work — mesh is fully transparent.

---

## What Kiali shows

| Demo stage | Kiali topology |
|------------|----------------|
| Step 2 (VM enrolled) | Single `eshoplite` node, mTLS lock icon, request rate |
| Step 3 (first microservice extracted) | Two nodes with animated traffic split lines — the strangler-fig pattern is visually self-evident |

---

## Why sidecar mode (not ambient)

- **KubeVirt masquerade + ztunnel = incompatible** — both write conflicting iptables
  `PREROUTING` rules in the same pod netns; traffic intercept ordering is
  non-deterministic and Waypoint HBONE tunnels fail with 503.
- **Istio CNI removes the SCC conflict** — no `istio-init` init-container competing
  with `virt-launcher`'s `NET_ADMIN` privilege. Istio CNI sets up iptables from the
  host side. This is the required mode for OpenShift Virt on ARO.
- **Full L7 Kiali telemetry** — sidecar mode exposes request metrics, mTLS status,
  and distributed traces in Kiali just as well as ambient for this demo.
- Tradeoff: VM must be restarted once after namespace label is applied for injection.

---

## Troubleshooting

**Kiali graph empty after enabling mesh:**
Kiali needs live traffic. Run the curl loop above. Also confirm the sidecar is injected:
```bash
oc get pod -n eshoplite-vm -l app=eshoplite-vm -o jsonpath='{.items[0].spec.containers[*].name}'
# should include: compute  guest-console-log  istio-proxy
```
Also check: `oc get namespace eshoplite-vm -o jsonpath='{.metadata.labels}'` — should
show `istio-injection: enabled`.

**Which URL should I hit in step 2?**
Use the Istio ingress Route, not the original app Route:
```bash
oc get route eshoplite-ingress -n istio-system -o jsonpath='{.spec.host}'
```
If you keep using the original Route in `eshoplite-vm`, traffic bypasses the mesh and
your `Gateway` / `VirtualService` rules will not participate.

**Check ztunnel is capturing the namespace:**
```bash
oc get namespace eshoplite-vm --show-labels
oc get pods -n eshoplite-vm -o wide
# ztunnel logs for this namespace:
oc logs -n istio-system -l app=ztunnel --tail=50 | grep eshoplite
```

**502 after enabling mesh (KubeVirt masquerade networking):**
KubeVirt `masquerade` mode NATs port 5000 through QEMU userspace — port 5000 is not
bound directly in the pod netns. Ztunnel intercepts at the pod netns boundary and gets
`Connection refused`. The VM spec in `step1-vm/vm.yaml` includes:
```yaml
annotations:
  traffic.sidecar.istio.io/excludeInboundPorts: "5000"
```
This tells ztunnel to leave inbound port 5000 alone, letting traffic flow through QEMU
normally. If you ever redeploy the VM without this annotation, 502s will return.

**Full mesh health check:**
```bash
oc get istio,istiocni,ztunnel -A
oc get pods -n istio-system
oc get pods -n tracing-system
```
