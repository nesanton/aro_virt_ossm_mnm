# Step 2 — OSSM Demo Toggle

## What's deployed (always on)

The `step2-ossm-operators` ArgoCD Application installs:

- **Sail Operator** (OSSM 3.x / Istio v1.28) + `istiod` + Istio CNI DaemonSet
- **ZTunnel** DaemonSet (one pod per node — ambient L4 capture)
- **Kiali** (traffic topology UI)
- **Tempo** (distributed tracing backend, in-memory)

These stay running permanently. They do not affect app traffic until the mesh is enabled.

**Kiali URL:**
```
https://kiali-istio-system.apps.hkw79nhv.swedencentral.aroapp.io
```

---

## Demo flow — "before and after mesh"

### Show "before mesh" state

The app is running. The `eshoplite-vm` namespace has no ambient label. Kiali shows
nothing for `eshoplite-vm` (no enrolled workloads). Route and app work normally.

### Enable the mesh (before → after)

```bash
source .env
oc login ${ARO_API%/} -u ${ARO_ADMIN_USER} -p ${ARO_ADMIN_PASSWORD} --insecure-skip-tls-verify=true

GIT_REPO_ORG=$(echo "$GIT_REPO_URL" | sed 's|https://github.com/||')
sed "s|YOUR_ORG/aro-ossm-ghcp.git|${GIT_REPO_ORG}|g" \
  deploy/argocd/application-ossm-config.yaml | oc apply -f -
```

Or in the **ArgoCD UI**: click `+ New App` → paste `deploy/step2-ossm/mesh-config` as
the path, or sync the pre-created `step2-ossm-config` application if it already exists.

**Effect:** ArgoCD adds `istio.io/dataplane-mode: ambient` to the `eshoplite-vm`
namespace. **No VM restart needed.** ZTunnel begins capturing traffic immediately.

After ~30 seconds, open Kiali — the `eshoplite` service node will appear.
Generate some traffic to populate the graph:

```bash
for i in $(seq 1 20); do
  curl -sk https://eshoplite-eshoplite-vm.apps.hkw79nhv.swedencentral.aroapp.io -o /dev/null
  sleep 1
done
```

### Disable the mesh (after → before)

```bash
sed "s|YOUR_ORG/aro-ossm-ghcp.git|${GIT_REPO_ORG}|g" \
  deploy/argocd/application-ossm-config.yaml | oc delete -f -
```

Or in the **ArgoCD UI**: delete the `step2-ossm-config` application (with cascade prune).

**Effect:** ArgoCD removes the ambient label from `eshoplite-vm`. ZTunnel stops
capturing traffic for that namespace. App continues to work — mesh is fully transparent.

---

## What Kiali shows

| Demo stage | Kiali topology |
|------------|----------------|
| Step 2 (VM enrolled) | Single `eshoplite` node, mTLS lock icon, request rate |
| Step 3 (first microservice extracted) | Two nodes with animated traffic split lines — the strangler-fig pattern is visually self-evident |

---

## Ambient vs sidecar — why ambient

- **No VM restart required** — ztunnel captures at the node CNI layer, no sidecar to inject
- **No SCC conflicts** — no `istio-init` init-container competing with `virt-launcher`'s privileges
- Tradeoff: Kiali ambient topology in v2.x is slightly less detailed than sidecar mode,
  but sufficient for the demo story

---

## Troubleshooting

**Kiali graph empty after enabling mesh:**
Kiali needs live traffic. Run the curl loop above.
Also check: `oc get namespace eshoplite-vm -o jsonpath='{.metadata.labels}'` — should
show `istio.io/dataplane-mode: ambient`.

**Check ztunnel is capturing the namespace:**
```bash
oc get namespace eshoplite-vm --show-labels
oc get pods -n eshoplite-vm -o wide
# ztunnel logs for this namespace:
oc logs -n istio-system -l app=ztunnel --tail=50 | grep eshoplite
```

**Full mesh health check:**
```bash
oc get istio,istiocni,ztunnel -A
oc get pods -n istio-system
oc get pods -n tracing-system
```
