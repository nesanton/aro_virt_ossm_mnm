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
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  channel: stable
  installPlanApproval: Automatic
  name: kubevirt-hyperconverged
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# HyperConverged CR triggers the actual CNV deployment
oc apply -f - <<'EOF'
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec: {}
EOF

echo "==> Waiting for OpenShift Virtualization to be ready (up to 10 min)..."
oc wait hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv \
  --for=condition=Available \
  --timeout=600s
echo "    OpenShift Virtualization ready."

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

# Substitute the placeholder before applying
sed "s|https://github.com/YOUR_ORG/aro-ossm-ghcp.git|${GIT_REPO_URL}|g" \
  "${SCRIPT_DIR}/argocd/app-project.yaml" | oc apply -f -

sed "s|https://github.com/YOUR_ORG/aro-ossm-ghcp.git|${GIT_REPO_URL}|g" \
  "${SCRIPT_DIR}/argocd/application.yaml" | oc apply -f -

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
echo "    Note: VM first boot takes ~5\u201310 min (cloud-init installs .NET + app)."
