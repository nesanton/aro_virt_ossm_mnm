#!/usr/bin/env bash
set -euo pipefail

# Load .env if present (vars in the file, or export them before running)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/.env" ]] && set -a && source "${SCRIPT_DIR}/.env" && set +a

# Required environment variables:
#   ARO_API
#   KUBEADMIN_PASSWORD
#
# Optional:
#   KUBEADMIN_USER (default: kubeadmin)
#   ARO_ADMIN_USER (default: admin)
#   HTPASSWD_IDP_NAME (default: local-admins)
#   HTPASSWD_SECRET_NAME (default: htpass-secret)

: "${ARO_API:?Please set ARO_API, e.g. https://api.<cluster>.<domain>:6443}"
: "${KUBEADMIN_PASSWORD:?Please set KUBEADMIN_PASSWORD}"

# Strip trailing slash from ARO_API if present
ARO_API="${ARO_API%/}"

KUBEADMIN_USER="${KUBEADMIN_USER:-kubeadmin}"
ARO_ADMIN_USER="${ARO_ADMIN_USER:-admin}"
HTPASSWD_IDP_NAME="${HTPASSWD_IDP_NAME:-local-admins}"
HTPASSWD_SECRET_NAME="${HTPASSWD_SECRET_NAME:-htpass-secret}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

need_cmd oc
need_cmd openssl
command -v htpasswd >/dev/null 2>&1 || need_cmd python3

ARO_ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -d '\n' | tr '/+' '_-')"
HTPASSWD_FILE="${WORKDIR}/users.htpasswd"

echo "Logging into cluster..."
oc login "${ARO_API}" -u "${KUBEADMIN_USER}" -p "${KUBEADMIN_PASSWORD}" --insecure-skip-tls-verify=true >/dev/null

echo "Creating htpasswd file for ${ARO_ADMIN_USER}..."
if command -v htpasswd >/dev/null 2>&1; then
  htpasswd -Bbn "${ARO_ADMIN_USER}" "${ARO_ADMIN_PASSWORD}" > "${HTPASSWD_FILE}"
else
  # Python bcrypt outputs $2b$ prefix; OpenShift requires $2y$ (identical algorithm)
  HTPASSWD_HASH="$(python3 -c "import bcrypt, sys; pw=sys.argv[1].encode(); h=bcrypt.hashpw(pw, bcrypt.gensalt(rounds=12)).decode(); print(sys.argv[2] + ':' + h.replace('\$2b\$', '\$2y\$', 1))" "${ARO_ADMIN_PASSWORD}" "${ARO_ADMIN_USER}")"
  printf '%s\n' "${HTPASSWD_HASH}" > "${HTPASSWD_FILE}"
fi

echo "Creating/updating secret ${HTPASSWD_SECRET_NAME} in openshift-config..."
oc -n openshift-config delete secret "${HTPASSWD_SECRET_NAME}" --ignore-not-found=true >/dev/null
oc -n openshift-config create secret generic "${HTPASSWD_SECRET_NAME}" \
  --from-file=htpasswd="${HTPASSWD_FILE}" >/dev/null

echo "Configuring OAuth htpasswd identity provider..."
cat <<EOF | oc apply -f - >/dev/null
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: ${HTPASSWD_IDP_NAME}
    mappingMethod: claim
    type: HTPasswd
    htpasswd:
      fileData:
        name: ${HTPASSWD_SECRET_NAME}
EOF

echo "Waiting for authentication operator to settle..."
oc wait --for=condition=Available clusteroperator/authentication --timeout=300s >/dev/null
echo "Waiting for oauth-openshift pods to roll out..."
oc -n openshift-authentication rollout status deployment/oauth-openshift --timeout=300s

echo "Granting cluster-admin to ${ARO_ADMIN_USER}..."
oc adm policy add-cluster-role-to-user cluster-admin "${ARO_ADMIN_USER}" >/dev/null

echo
echo "ARO_ADMIN_USER=${ARO_ADMIN_USER}"
echo "ARO_ADMIN_PASSWORD=${ARO_ADMIN_PASSWORD}"