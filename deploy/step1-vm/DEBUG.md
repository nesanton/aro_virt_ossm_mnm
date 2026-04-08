# Step 1 — Route Debug Runbook

**Symptom:** VM is running but the Route returns 503 or a connection error.

---

## 1. Fast triage — check pod and endpoint readiness

```bash
# Is the virt-launcher pod fully ready? (should be 1/1 in step1, 2/2 in step2)
oc get pods -n eshoplite-vm -l app=eshoplite-vm

# Are there any ready endpoints on the Service?
oc get endpoints eshoplite -n eshoplite-vm

# Is the Route healthy?
oc get route eshoplite -n eshoplite-vm
```

**Expected in step1:**
- Pod: `1/1 Running`
- Endpoints: `<pod-ip>:5000`
- Route: `HOST/PORT` column shows the auto-assigned hostname

**If pod shows `1/2`:** → jump to section 3 (unexpected sidecar)

**If endpoints are empty (`<none>`):** → check pod readiness (section 2) and cloud-init (section 5)

---

## 2. Describe the pod — read events and container statuses

```bash
oc describe pod -n eshoplite-vm -l app=eshoplite-vm
```

Look for:
- `Readiness probe failed` — identifies which container is not ready
- `Back-off restarting failed container` — init or app container crash
- `FailedMount` / `FailedSchedule` — storage or node issues

---

## 3. Diagnose unexpected sidecar injection (pod shows `1/2`)

This is the most common cause of 503 in step1. The OSSM webhook injects
`istio-proxy` if the pod carries `sidecar.istio.io/inject: "true"` OR if
the namespace has `istio-injection: enabled`. In step1 neither should be true.

```bash
# List containers in the virt-launcher pod — should be only "compute"
oc get pod -n eshoplite-vm -l app=eshoplite-vm \
  -o jsonpath='{.items[0].spec.containers[*].name}'
echo

# Check namespace labels — must NOT have istio-injection=enabled in step1
oc get namespace eshoplite-vm --show-labels

# Check VMI template annotations — must NOT have sidecar.istio.io/inject: "true"
oc get vm eshoplite-vm -n eshoplite-vm \
  -o jsonpath='{.spec.template.metadata.annotations}' | python3 -m json.tool
```

**If `istio-proxy` is listed as a container and the namespace lacks `istio-injection=enabled`:**
the pod annotation `sidecar.istio.io/inject: "true"` was inadvertently added to vm.yaml.
This was fixed in commit [fix: remove sidecar inject annotation from step1 VMI template].
Apply the fix and bounce the VM:

```bash
# Re-apply the fixed manifest
oc apply -k deploy/step1-vm/

# Bounce the VM so the new pod (without sidecar) is created
oc delete vmi eshoplite-vm -n eshoplite-vm
# KubeVirt re-creates the VMI automatically (VM has running: true)
```

**If istio-proxy readiness probe is failing (`port 15021 connection refused`):**
This is the D-008 failure: KubeVirt masquerade iptables rules conflict with
Envoy startup. The fix above (removing the annotation from vm.yaml) eliminates
the injection entirely in step1, which resolves this.

---

## 4. Test the route directly

```bash
ROUTE=$(oc get route eshoplite -n eshoplite-vm -o jsonpath='{.spec.host}')
echo "Route host: $ROUTE"

# Edge TLS — follow redirects
curl -Lk "https://$ROUTE/"
```

- `200 OK` with HTML → route is working ✅
- `503 Service Unavailable` → no ready endpoints (back to sections 2–3)
- `504 Gateway Timeout` → endpoints exist but app isn't responding (check cloud-init, section 5)

---

## 5. Cloud-init / app startup status

The app installs .NET 9 SDK and builds on first boot. This takes **5–15 minutes**.
The route will time out until cloud-init finishes.

```bash
# Check the VMI state
oc get vmi eshoplite-vm -n eshoplite-vm

# Open the VM serial console to read cloud-init logs
# (Ctrl+] to exit)
virtctl console eshoplite-vm -n eshoplite-vm
```

Inside the console:

```bash
# Check cloud-init log (streamed during boot)
sudo tail -f /var/log/eshoplite-init.log

# Check sentinel (written at end of cloud-init)
cat /var/log/eshoplite-init-done

# Check app service
systemctl status eshoplite.service
sudo journalctl -u eshoplite.service -n 50

# Test app directly inside the VM
curl http://127.0.0.1:5000/
```

**If sentinel file says `FAILED`:** re-run setup:

```bash
# SSH into the VM via virtctl port-forward (from your local machine):
virtctl port-forward vmi/eshoplite-vm 2222:22 -n eshoplite-vm &
ssh -i ~/.ssh/aro-demo-vm -p 2222 cloud-user@localhost \
  "sudo bash ~/setup-app.sh"
```

---

## 6. Service selector sanity check

```bash
# Confirm Service selector matches VMI pod labels
oc get svc eshoplite -n eshoplite-vm -o yaml | grep -A5 selector

# Confirm VMI pod carries the matching label
oc get pod -n eshoplite-vm -l app=eshoplite-vm --show-labels
```

Both should show `app=eshoplite-vm`. If the endpoint is still empty after the
pod is `1/1 Running`, the selector is mismatched — check vm.yaml
`spec.template.metadata.labels` vs service.yaml `spec.selector`.

---

## 7. Step 2 specific — sidecar readiness after OSSM enrollment

When you apply `step2-ossm-config` (which sets `istio-injection: enabled` on the
namespace), bounce the VM to inject the sidecar:

```bash
oc delete vmi eshoplite-vm -n eshoplite-vm
# KubeVirt recreates the VMI; new virt-launcher pod will be 2/2
```

Verify sidecar is injected and healthy:

```bash
oc get pod -n eshoplite-vm -l app=eshoplite-vm
# Expected: 2/2 Running

# Check istio-proxy readiness
oc logs -n eshoplite-vm -l app=eshoplite-vm -c istio-proxy | tail -20
```

If `istio-proxy` is `0/2` (readiness failing on port 15021), check:
1. Istio CNI DaemonSet is running: `oc get pods -n istio-system -l app=istio-cni-node`
2. The vm.yaml VMI template has `traffic.sidecar.istio.io/kubevirtInterfaces: k6t-eth0` (present by default)
3. `oc describe pod -l app=eshoplite-vm -n eshoplite-vm` — look for `istio-init` init container errors
   (if present: Istio CNI is not active; re-check IstioCNI CR installation)
