#!/usr/bin/env bash
# Build and push cap-evolve-harbor-runner to the cluster's internal OpenShift registry.
# Prerequisites: oc logged in, podman, oc registry login (or run this script — it logs in).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

NAMESPACE="${NAMESPACE:-skill-optimization}"
IMAGE_NAME="${IMAGE_NAME:-cap-evolve-harbor-runner}"
TAG="${TAG:-latest}"
PLATFORM="${PLATFORM:-linux/amd64}"

REGISTRY="$(oc registry info)"
LOCAL_TAG="${IMAGE_NAME}:${TAG}"
REMOTE="${REGISTRY}/${NAMESPACE}/${IMAGE_NAME}:${TAG}"

echo "Registry: ${REGISTRY}"
echo "Remote:   ${REMOTE}"

oc registry login

podman build --platform "${PLATFORM}" \
  -t "${LOCAL_TAG}" \
  -f openshift/images/cap-evolve-harbor-runner/Dockerfile .

podman tag "${LOCAL_TAG}" "${REMOTE}"
podman push "${REMOTE}"

echo "Pushed ${REMOTE}"
echo "In-cluster pull: image-registry.openshift-image-registry.svc:5000/${NAMESPACE}/${IMAGE_NAME}:${TAG}"
