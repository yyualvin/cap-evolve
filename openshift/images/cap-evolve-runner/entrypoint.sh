#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${OPENSHIFT_NAMESPACE:-skill-optimization}"
TOKEN_FILE="/var/run/secrets/kubernetes.io/serviceaccount/token"
CA_FILE="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
API_SERVER="https://kubernetes.default.svc"

if [[ -f "${TOKEN_FILE}" ]]; then
  echo "Logging into OpenShift with in-cluster service account token"
  oc login --token="$(<"${TOKEN_FILE}")" \
    --server="${API_SERVER}" \
    --certificate-authority="${CA_FILE}" >/dev/null
  # `oc project` calls the OpenShift Project API and requires `get` on
  # projects.project.openshift.io, which this service account does not have
  # (harbor-rbac.yaml only grants pods/builds/imagestreams). Set the
  # current-context namespace directly instead: this is a local kubeconfig
  # edit with no API call, so it can't fail on RBAC, and Harbor's openshift
  # backend relies on this context namespace whenever it isn't passed an
  # explicit namespace (see harbor/environments/openshift.py).
  oc config set-context --current --namespace="${NAMESPACE}"
else
  echo "No in-cluster service account token found, skipping oc login"
fi

mkdir -p /workspace

# .capevolve/project holds run history and any evolved capability/adapter state
# on the PVC — seed it once and never overwrite it on later restarts.
if [[ ! -d /workspace/.capevolve/project ]]; then
  echo "Seeding /workspace/.capevolve from baked-in project files"
  mkdir -p /workspace/.capevolve
  cp -a /opt/cap-evolve-seed/.capevolve/project /workspace/.capevolve/
else
  echo "Workspace already seeded; preserving existing /workspace/.capevolve/project"
fi

# openshift/*.sh and task id files are deploy-time config, not run state — always
# refresh them from the image so a rebuild takes effect without wiping run history.
echo "Refreshing /workspace/openshift from baked-in image files"
mkdir -p /workspace/openshift
cp -a /opt/cap-evolve-seed/openshift/. /workspace/openshift/

cd /workspace
mkdir -p /workspace/.venv/bin
ln -sf "$(command -v cap-evolve)" /workspace/.venv/bin/cap-evolve
mkdir -p /tmp/.local/bin
ln -sf "$(command -v harbor)" /tmp/.local/bin/harbor

echo "Starting openshift/run.sh from /workspace"
set +e
bash ./openshift/run.sh
run_rc=$?
set -e
echo "openshift/run.sh exited with code ${run_rc}"
echo "Keeping pod alive for dashboard, logs, and result retrieval"
sleep infinity
