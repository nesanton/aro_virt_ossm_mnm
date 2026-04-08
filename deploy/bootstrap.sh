#!/usr/bin/env bash
# ------------------------------------------------------------
# bootstrap.sh — Install operators + register ArgoCD collateral
#
# Run this ONCE after:
#   1. oc login to the cluster (as cluster-admin)
#   2. GIT_REPO_URL set in .env (or exported in shell)
#
# What this script does:
#   a. Installs OpenShift GitOps operator (if not already present)
#   b. Installs OpenShift Virtualization operator (if not already present)
#   c. Waits for both operators to be ready
#   d. Registers ArgoCD AppProject + Application (ArgoCD takes over from here)
#
# After this runs, ArgoCD syncs deploy/step1-vm/ automatically.
# You should not need to run this again unless you nuke the cluster.
#
# Usage:
#   source .env
#   ./deploy/bootstrap.sh
# ------------------------------------------------------------
set -euo pipefail

# ---- Load .env ----------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/../.env" ]] && set -a && source "${SCRIPT_DIR}/../.env" && set +a

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
GIT_REPO_URL="${GIT_REPO_URL:-}"
GIT_USERNAME="${GIT_USERNAME:-}"
GIT_TOKEN="${GIT_TOKEN:-}"

# ---- Preflight: cluster access ------------------------------
echo "==> Verifying cluster access..."
oc whoami || { echo "ERROR: Not logged in. Run 'oc login' first."; exit 1; }

# ---- SSH keypair for VM debug access -----------------------
VM_KEY="$HOME/.ssh/aro-demo-vm"
if [ ! -f "$VM_KEY" ]; then
  echo "[ssh] Generating VM debug keypair at $VM_KEY"
  ssh-keygen -t ed25519 -f "$VM_KEY" -N "" -C "aro-demo-vm@$(hostname)"
fi

# ---- Install OpenShift GitOps operator ----------------------
echo ""
echo "==> Installing OpenShift GitOps operator (idempotent)..."
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: latest
  installPlanApproval: Automatic
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "==> Waiting for GitOps operator to install (up to 5 min)..."
# Wait for the ArgoCD server pod — created by the operator after install
timeout 300 bash -c "
  until oc get pods -n '${ARGOCD_NAMESPACE}' -l app.kubernetes.io/name=openshift-gitops-server \
        --ignore-not-found -o name 2>/dev/null | grep -q pod; do
    echo '    ... waiting for ArgoCD server pod to appear'; sleep 15
  done
"
oc wait --for=condition=ready pod \
  -l app.kubernetes.io/name=openshift-gitops-server \
  -n "${ARGOCD_NAMESPACE}" \
  --timeout=120s
echo "    GitOps operator ready."

# ---- Install OpenShift Virtualization operator --------------
echo ""
echo "==> Installing OpenShift Virtualization operator (idempotent)..."
# The Namespace, OperatorGroup, and Subscription must all be applied together
# before the HyperConverged CR. OLM does NOT auto-create openshift-cnv.
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
    - openshift-cnv
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: openshift-cnv
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: kubevirt-hyperconverged
  channel: "stable"
  installPlanApproval: Automatic
EOF

echo "==> Waiting for HyperConverged operator CSV to be ready (up to 10 min)..."
timeout 600 bash -c "
  until oc get csv -n openshift-cnv 2>/dev/null \
        | grep -E 'kubevirt-hyperconverged-operator.*Succeeded'; do
    echo '    ... waiting for CSV'; sleep 20
  done
"

# HyperConverged CR triggers the full CNV component deployment
echo "==> Creating HyperConverged CR..."
oc apply -f - <<'EOF'
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec: {}
EOF

echo "==> Waiting for OpenShift Virtualization to be ready (up to 15 min)..."
oc wait hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv \
  --for=condition=Available \
  --timeout=900s
echo "    OpenShift Virtualization ready."

# ---- Provision D8s_v5 MachineSet for Virt workloads --------
# OpenShift Virtualization on ARO requires >= 8-core workers (Dsv5 family).
# Default ARO workers are D4s_v5 (4 cores) — too small.
# This creates ONE D8s_v5 worker in zone 1. One is enough for this demo
# (no live migration, no HA). Idempotent: existing MachineSet is left alone.
echo ""
echo "==> Provisioning D8s_v5 worker MachineSet for Virt (idempotent)..."

# Derive cluster topology from existing MachineSets — works after cluster recreate
CLUSTER_ID=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].metadata.labels.machine\.openshift\.io/cluster-api-cluster}')
LOCATION=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.location}')
RESOURCE_GROUP=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.resourceGroup}')
NETWORK_RG=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.networkResourceGroup}')
VNET=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.vnet}')
SUBNET=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.subnet}')
IMAGE_SKU=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.image.sku}')
IMAGE_VER=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.image.version}')
VIRT_MS_NAME="${CLUSTER_ID}-virt-${LOCATION}1"

if oc get machineset "${VIRT_MS_NAME}" -n openshift-machine-api &>/dev/null; then
  echo "    MachineSet ${VIRT_MS_NAME} already exists — skipping."
else
  echo "    Creating MachineSet ${VIRT_MS_NAME} (Standard_D8s_v5, zone 1)..."
  cat <<EOF | oc apply -f -
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  name: ${VIRT_MS_NAME}
  namespace: openshift-machine-api
  labels:
    machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID}
spec:
  replicas: 1
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID}
      machine.openshift.io/cluster-api-machineset: ${VIRT_MS_NAME}
  template:
    metadata:
      labels:
        machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID}
        machine.openshift.io/cluster-api-machine-role: worker
        machine.openshift.io/cluster-api-machine-type: worker
        machine.openshift.io/cluster-api-machineset: ${VIRT_MS_NAME}
        # Taint label so only Virt workloads land here (KubeVirt respects this)
        node-role.kubernetes.io/worker: ""
    spec:
      metadata:
        labels:
          node-role.kubernetes.io/worker: ""
          workload-type: virtualization
      taints:
        - key: kubevirt.io/drain
          effect: NoSchedule
          # Removed automatically by CNV when the node is ready for VM workloads
      providerSpec:
        value:
          apiVersion: machine.openshift.io/v1beta1
          kind: AzureMachineProviderSpec
          location: ${LOCATION}
          zone: "1"
          vmSize: Standard_D8s_v5
          resourceGroup: ${RESOURCE_GROUP}
          networkResourceGroup: ${NETWORK_RG}
          vnet: ${VNET}
          subnet: ${SUBNET}
          image:
            offer: aro4
            publisher: azureopenshift
            resourceID: ""
            sku: ${IMAGE_SKU}
            type: MarketplaceNoPlan
            version: ${IMAGE_VER}
          osDisk:
            diskSizeGB: 128
            managedDisk:
              storageAccountType: Premium_LRS
            osType: Linux
          publicIP: false
          userDataSecret:
            name: worker-user-data
          credentialsSecret:
            name: azure-cloud-credentials
            namespace: openshift-machine-api
EOF

  echo "==> Waiting for Virt worker node to be Ready (up to 15 min)..."
  timeout 900 bash -c "
    until oc get nodes -l workload-type=virtualization --no-headers 2>/dev/null \
          | grep -q ' Ready '; do
      echo '    ... waiting for node'; sleep 20
    done
  "
  echo "    Virt worker node is Ready."
fi

# ---- (Optional) Register private repo credentials ----------
if [[ -n "${GIT_REPO_URL}" && -n "${GIT_TOKEN}" ]]; then
  echo ""
  echo "==> Registering repo credentials in ArgoCD..."
  ARGOCD_PASSWORD=$(oc get secret openshift-gitops-cluster \
    -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath='{.data.admin\.password}' | base64 -d)
  ARGOCD_SERVER=$(oc get route openshift-gitops-server \
    -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath='{.spec.host}')

  argocd login "${ARGOCD_SERVER}" \
    --username admin \
    --password "${ARGOCD_PASSWORD}" \
    --grpc-web --insecure
  argocd repo add "${GIT_REPO_URL}" \
    --username "${GIT_USERNAME:-token}" \
    --password "${GIT_TOKEN}" \
    --grpc-web
else
  echo "==> Skipping repo credential registration (GIT_TOKEN not set \u2014 assuming public repo)."
fi

# ---- Apply ArgoCD collateral --------------------------------
echo ""
echo "==> Patching repo URL in Application manifest..."
if [[ -z "${GIT_REPO_URL}" ]]; then
  echo "ERROR: GIT_REPO_URL is not set. Add it to .env and re-run." >&2
  exit 1
fi

# ---- Grant ArgoCD permissions to manage app namespaces -----
# The OpenShift GitOps operator restricts the ArgoCD SA to its own namespace
# by default. Labeling target namespaces with argocd.argoproj.io/managed-by
# causes the operator to create the necessary RoleBindings automatically.
# VirtualMachine CRDs also need a ClusterRole (no namespace-scoped workaround).
echo "==> Granting ArgoCD permissions for app namespaces..."

# Ensure the app namespace exists with the managed-by label (idempotent)
oc create namespace eshoplite-vm --dry-run=client -o yaml | oc apply -f -
oc label namespace eshoplite-vm \
  argocd.argoproj.io/managed-by=openshift-gitops \
  --overwrite

# ClusterRoleBinding for VirtualMachine / KubeVirt CRDs
oc apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: openshift-gitops-virt-manager
subjects:
  - kind: ServiceAccount
    name: openshift-gitops-argocd-application-controller
    namespace: openshift-gitops
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
EOF
echo "    Permissions granted."

# ---- Copy global pull secret into app namespace -------------
# quay.io/containerdisks/rhel8 requires Red Hat credentials.
# The cluster global pull-secret contains them; copy into app namespace.
echo "==> Copying pull secret into eshoplite-vm namespace..."
oc get secret pull-secret -n openshift-config -o json | python3 -c "
import json, sys
s = json.load(sys.stdin)
s['metadata'] = {'name': 'redhat-pull-secret', 'namespace': 'eshoplite-vm'}
print(json.dumps(s))
" | oc apply -f -
oc secrets link default redhat-pull-secret --for=pull -n eshoplite-vm 2>/dev/null || true
echo "    Pull secret ready."

# ---- Create cloud-init secret with real SSH public key -----
# IMPORTANT: This secret is NOT in kustomization.yaml and NOT managed by ArgoCD.
# Bootstrap owns it. Creating it BEFORE the ArgoCD Application is applied ensures
# cloud-init gets the real key — ArgoCD self-heal cannot revert it.
echo ""
echo "==> Creating eshoplite-cloudinit secret with SSH public key..."
VM_PUBKEY=$(cat "$HOME/.ssh/aro-demo-vm.pub")
USERDATA=$(python3 -c "
import yaml, sys
with open('${SCRIPT_DIR}/step1-vm/cloudinit-secret.yaml') as f:
    doc = yaml.safe_load(f)
ud = doc['stringData']['userdata']
ud = ud.replace('ssh_authorized_keys: []', 'ssh_authorized_keys:\n  - $VM_PUBKEY')
print(ud)
")
oc create namespace eshoplite-vm --dry-run=client -o yaml | oc apply -f -
oc create secret generic eshoplite-cloudinit \
  --from-literal=userdata="$USERDATA" \
  -n eshoplite-vm --dry-run=client -o yaml | oc apply -f -
echo "    Secret created with real SSH public key."

# Substitute the placeholder before applying
sed "s|https://github.com/YOUR_ORG/aro-ossm-ghcp.git|${GIT_REPO_URL}|g" \
  "${SCRIPT_DIR}/argocd/app-project.yaml" | oc apply -f -

sed "s|https://github.com/YOUR_ORG/aro-ossm-ghcp.git|${GIT_REPO_URL}|g" \
  "${SCRIPT_DIR}/argocd/application.yaml" | oc apply -f -

# ---- Delete + recreate VM to force clean cloud-init run ----
echo ""
echo "==> Deleting VM and PVC to force fresh cloud-init provisioning..."
oc delete vm eshoplite-vm -n eshoplite-vm --ignore-not-found=true
oc delete pvc eshoplite-vm-rootdisk -n eshoplite-vm --ignore-not-found=true
oc wait --for=delete vmi/eshoplite-vm -n eshoplite-vm --timeout=120s 2>/dev/null || true
echo "==> Recreating VM only (not full kustomize — that would reset the patched secret)..."
# IMPORTANT: apply only vm.yaml here, NOT `oc apply -k step1-vm/`
# kustomize would overwrite the cloud-init secret back to the placeholder.
# All other resources (namespace, service, route) were already applied via ArgoCD above.
oc apply -f "${SCRIPT_DIR}/step1-vm/vm.yaml"
echo "    VM recreated — cloud-init will run fresh on first boot."

# ---- Done ---------------------------------------------------
ARGOCD_UI_HOST=$(oc get route openshift-gitops-server \
  -n "${ARGOCD_NAMESPACE}" \
  -o jsonpath='{.spec.host}' 2>/dev/null || echo "<argocd-route-host>")

echo ""
echo "==> Done. ArgoCD will now sync deploy/step1-vm/ from Git."
echo ""
echo "    ArgoCD UI:  https://${ARGOCD_UI_HOST}"
echo "    Watch sync: oc get application eshoplite-step1-vm -n ${ARGOCD_NAMESPACE} -w"
echo "    App URL:    oc get route eshoplite -n eshoplite-vm -o jsonpath='{.spec.host}'"
echo ""
echo "==> VM is provisioning. Cloud-init will complete in ~2 minutes (SSH key + password only)."
echo "==> Once the VM is Running, connect with:"
echo "    virtctl console eshoplite-vm -n eshoplite-vm  (user: cloud-user / redhat)"
echo "    OR"
echo "    virtctl port-forward vmi/eshoplite-vm -n eshoplite-vm 2222:22 &"
echo "    ssh -i ~/.ssh/aro-demo-vm -p 2222 cloud-user@127.0.0.1"
echo ""
echo "==> Then run the app setup:"
echo "    source .env"
echo "    scp -i ~/.ssh/aro-demo-vm -P 2222 -o StrictHostKeyChecking=no deploy/step1-vm/setup-app.sh cloud-user@127.0.0.1:~/"
echo "    ssh -i ~/.ssh/aro-demo-vm -p 2222 -o StrictHostKeyChecking=no cloud-user@127.0.0.1 \\"
echo "      \"export RHSM_USERNAME=\$(printf '%q' \"\$RHSM_USERNAME\"); export RHSM_PASSWORD=\$(printf '%q' \"\$RHSM_PASSWORD\"); bash ~/setup-app.sh\""
echo "    # printf '%q' safely shell-escapes special characters in credentials"

echo ""
echo "# ============================================================"
echo "# STEP 2: OpenShift Service Mesh (OSSM 3.x — Sidecar Mode)"
echo "# ============================================================"
echo "# Deploy operators + control plane (one-time, ~5-10 min for operators to install):"
echo "#"
echo "#   oc apply -f deploy/argocd/application-ossm-operators.yaml"
echo "#"
echo "# Wait for Sail Operator, Kiali Operator, and Tempo Operator to finish installing:"
echo "#   oc get subscriptions -n openshift-operators | grep -E 'servicemesh|kiali|tempo'"
echo "# Then watch Istio control plane and Kiali come up:"
echo "#   oc get istio,istiocni,kiali,tempomonolithic -A"
echo "#"
echo "# DEMO TOGGLE — 'with mesh' (sidecar injection, requires VM restart):"
echo "#   oc apply -f deploy/argocd/application-ossm-config.yaml"
echo "#   # OR sync manually in ArgoCD UI"
echo "#   # Sidecar mode: VM MUST be restarted after label for sidecar to be injected."
echo "#   # Restart VM: oc delete vmi eshoplite-vm -n eshoplite-vm  (VM controller recreates it)"
echo "#"
echo "# DEMO TOGGLE — 'without mesh':"
echo "#   oc delete -f deploy/argocd/application-ossm-config.yaml"
echo "#   # OR manually delete application-ossm-config in ArgoCD UI"
echo "#   # → prune removes the istio-injection=enabled label from eshoplite-vm namespace"
echo "#"
echo "# Kiali URL (once deployed):"
echo "#   oc get route kiali -n istio-system -o jsonpath='{.spec.host}'"
