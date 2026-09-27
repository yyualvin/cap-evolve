#!/usr/bin/env bash
# Test the LiteLLM proxy from OUTSIDE the cap-evolve namespace (laptop, CI, etc.).
#
# Three ways to reach the proxy:
#   1. Port-forward (no Route needed):
#        oc port-forward -n skill-optimization svc/litellm-proxy 4000:4000
#        ./openshift/scripts/test-litellm-proxy.sh http://localhost:4000
#   2. OpenShift Route (after oc apply -f litellm-proxy.yaml):
#        ./openshift/scripts/test-litellm-proxy.sh https://litellm-proxy-skill-optimization.apps.<cluster>
#   3. From another namespace on the same cluster (no Route):
#        ./openshift/scripts/test-litellm-proxy.sh http://litellm-proxy.skill-optimization.svc.cluster.local:4000
#
# Auth: set LITELLM_MASTER_KEY, or leave unset to read litellm-proxy Secret via oc.
set -euo pipefail

NAMESPACE="${LITELLM_NAMESPACE:-skill-optimization}"
BASE_URL="${1:-http://localhost:4000}"
BASE_URL="${BASE_URL%/}"
MODEL="${TEST_MODEL:-gpt-5.6-luna}"

if [ -z "${LITELLM_MASTER_KEY:-}" ] && command -v oc >/dev/null 2>&1; then
  LITELLM_MASTER_KEY="$(oc get secret litellm-proxy -n "$NAMESPACE" \
    -o jsonpath='{.data.LITELLM_MASTER_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)"
fi
KEY="${LITELLM_MASTER_KEY:-}"
if [ -z "$KEY" ]; then
  echo "error: LITELLM_MASTER_KEY is not set and could not be read from secret litellm-proxy in $NAMESPACE."
  echo "  export LITELLM_MASTER_KEY=\$(oc get secret litellm-proxy -n $NAMESPACE -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)"
  exit 1
fi

if [[ "$KEY" == "your-proxy-key" || "$KEY" == "<YOUR_LITELLM_MASTER_KEY>" ]]; then
  echo "::error:: LITELLM_MASTER_KEY is still a placeholder."
  echo "       oc get secret litellm-proxy -n skill-optimization -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d; echo"
  exit 1
fi
if [[ "$KEY" != sk-* ]]; then
  echo "::warning:: LiteLLM master keys should start with 'sk-' (auth may return HTTP 400 without a DB)."
fi

echo "==> health"
curl -fsS "$BASE_URL/health" -H "Authorization: Bearer $KEY" && echo

echo "==> models (GET /v1/models)"
MODELS_BODY="$(mktemp)"
MODELS_CODE=$(curl -sS -o "$MODELS_BODY" -w '%{http_code}' \
  "$BASE_URL/v1/models" -H "Authorization: Bearer $KEY")
echo "HTTP $MODELS_CODE"
if [ "$MODELS_CODE" -ge 400 ]; then
  cat "$MODELS_BODY"; echo
  echo "::warning:: /v1/models failed — usually wrong LITELLM_MASTER_KEY (must match the Secret exactly)."
  echo "           Continuing with /v1/messages probe (what Harbor/claude-code actually uses)."
else
  python3 -m json.tool "$MODELS_BODY" 2>/dev/null || cat "$MODELS_BODY"
  echo
fi
rm -f "$MODELS_BODY"

echo "==> anthropic messages probe (POST /v1/messages) model=$MODEL"
HTTP_CODE=$(curl -sS -o /tmp/litellm_probe.json -w '%{http_code}' \
  "$BASE_URL/v1/messages" \
  -H "Authorization: Bearer $KEY" \
  -H "content-type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}")
echo "HTTP $HTTP_CODE"
head -c 500 /tmp/litellm_probe.json; echo
if [ "$HTTP_CODE" -ge 400 ]; then
  echo "::error:: probe failed — check model_name in config.yaml matches TEST_MODEL"
  exit 1
fi

echo "OK — proxy reachable and model '$MODEL' responded."
