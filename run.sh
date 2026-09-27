#!/usr/bin/env bash
# cap-evolve + Harbor on OpenShift (SWE-bench-verified) via LiteLLM proxy.
#
# Prereqs:
#   - .venv with cap-evolve + harbor installed
#   - oc login (Harbor uses -e openshift)
#   - LiteLLM proxy deployed in skill-optimization (see openshift/README.md)
#   - Port-forward for the local optimizer (claude-code runs on your laptop):
#       oc port-forward -n skill-optimization svc/litellm-proxy 4000:4000
#
# Usage:
#   ./run.sh                          # pilot (50 tasks)
#   HARBOR_TASK_IDS_FILE=... ./run.sh # full 500-task run
#   RUN_TS=my-run ./run.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$REPO/.capevolve/project"
SPEC="$PROJECT/adapters/capevolve.yaml"
VENV="$REPO/.venv"
CAPEVOLVE="$VENV/bin/cap-evolve"

# Harbor CLI: venv first, then PATH (~/.local/bin from `uv tool install harbor`).
if [ -x "${HARBOR_BIN:-}" ]; then
  HARBOR="$HARBOR_BIN"
elif [ -x "$VENV/bin/harbor" ]; then
  HARBOR="$VENV/bin/harbor"
elif command -v harbor >/dev/null 2>&1; then
  HARBOR="$(command -v harbor)"
else
  HARBOR=""
fi

# --- LiteLLM / model -------------------------------------------------------
NAMESPACE="${LITELLM_NAMESPACE:-skill-optimization}"
MODEL="${HARBOR_MODEL:-gpt-5.6-luna}"
HARBOR_PROXY_URL="${HARBOR_AGENT_BASE_URL:-http://litellm-proxy.${NAMESPACE}.svc:4000}"
OPTIMIZER_PROXY_URL="${ANTHROPIC_BASE_URL:-${LITELLM_PROXY_LOCAL:-http://localhost:4000}}"

if [ -z "${LITELLM_MASTER_KEY:-}" ] && command -v oc >/dev/null 2>&1; then
  LITELLM_MASTER_KEY="$(oc get secret litellm-proxy -n "$NAMESPACE" \
    -o jsonpath='{.data.LITELLM_MASTER_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)"
fi
if [ -z "${LITELLM_MASTER_KEY:-}" ]; then
  echo "error: set LITELLM_MASTER_KEY or ensure oc can read secret litellm-proxy in $NAMESPACE" >&2
  exit 1
fi

# --- Harbor (evals on OpenShift) -------------------------------------------
TASK_IDS_FILE="${HARBOR_TASK_IDS_FILE:-$PROJECT/adapters/task_ids_pilot.txt}"
RUN_TS="${RUN_TS:-swebench-pilot}"

export HARBOR_BIN="$HARBOR"
export HARBOR_DATASET="${HARBOR_DATASET:-swe-bench/swe-bench-verified}"
export HARBOR_AGENT="${HARBOR_AGENT:-claude-code}"
export HARBOR_MODEL="$MODEL"
export HARBOR_PARALLEL="${HARBOR_PARALLEL:-16}"
export HARBOR_TIMEOUT="${HARBOR_TIMEOUT:-1800}"
export HARBOR_EXTRA_FLAGS="${HARBOR_EXTRA_FLAGS:--e openshift}"
export HARBOR_TASK_IDS="$(tr '\n' ',' < "$TASK_IDS_FILE" | sed 's/,$//')"
export HARBOR_AGENT_BASE_URL="$HARBOR_PROXY_URL"
export HARBOR_AGENT_API_KEY="$LITELLM_MASTER_KEY"

# --- Optimizer (local claude-code → LiteLLM via port-forward or Route) -----
unset CLAUDE_CODE_USE_VERTEX CLOUD_ML_REGION ANTHROPIC_VERTEX_PROJECT_ID
export ANTHROPIC_BASE_URL="$OPTIMIZER_PROXY_URL"
export ANTHROPIC_API_KEY="$LITELLM_MASTER_KEY"

# --- cap-evolve ------------------------------------------------------------
export PYTHONPATH="$PROJECT/adapters:$REPO"
export CAPEVOLVE_SKILLS_DIR="$REPO/skills"
export GIT_EDITOR=true

if [ ! -x "$CAPEVOLVE" ]; then
  echo "error: $CAPEVOLVE not found — run: pip install ./core" >&2
  exit 1
fi
if [ -z "$HARBOR" ] || [ ! -x "$HARBOR" ]; then
  echo "error: harbor CLI not found — install with: uv tool install harbor" >&2
  exit 1
fi
if [ ! -f "$SPEC" ]; then
  echo "error: spec not found: $SPEC" >&2
  exit 1
fi
if [ -f "$REPO/.capevolve/run_${RUN_TS}/baseline.json" ]; then
  echo "warning: .capevolve/run_${RUN_TS} already has a baseline — use RUN_TS=<new-name> or delete it" >&2
fi

echo "==> Harbor:  $HARBOR ($HARBOR_AGENT @ $MODEL on OpenShift, $HARBOR_PROXY_URL)"
echo "==> Optimizer: claude-code @ $MODEL via $OPTIMIZER_PROXY_URL"
echo "==> Tasks: $(echo "$HARBOR_TASK_IDS" | tr ',' '\n' | wc -l) from $(basename "$TASK_IDS_FILE")"
echo "==> Run dir: .capevolve/runs/$RUN_TS"

"$CAPEVOLVE" run \
  --spec "$SPEC" \
  --project "$PROJECT" \
  --run-ts "$RUN_TS" \
  --dashboard "${CAPEVOLVE_DASHBOARD:-auto}"
