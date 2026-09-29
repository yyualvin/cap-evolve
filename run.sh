#!/usr/bin/env bash
# cap-evolve + Harbor on OpenShift (SWE-bench-verified) via AI gateway.
#
# Prereqs:
#   - .venv with cap-evolve + harbor installed
#   - oc login (Harbor uses -e openshift)
#   - ANTHROPIC_API_KEY set (AI gateway key; do not commit it)
#   - Local claude-code installed (optimizer runs on your laptop)
#   - .capevolve/project/optimizer-claude/settings.json (GLM behavesAs)
#
# Usage:
#   export ANTHROPIC_API_KEY='sk-oai-...'
#   ./run.sh                          # pilot (50 tasks)
#   HARBOR_TASK_IDS_FILE=.../task_ids_mini.txt RUN_TS=mini ./run.sh  # 10-task smoke
#   HARBOR_TASK_IDS_FILE=.../task_ids.txt RUN_TS=full ./run.sh       # 500 tasks
set -euo pipefail

# Exports (esp. CLAUDE_CONFIG_DIR) must not stick in an interactive shell.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  echo "error: do not source run.sh — run it as ./run.sh" >&2
  return 1 2>/dev/null || exit 1
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$REPO/.capevolve/project"
SPEC="$PROJECT/adapters/capevolve.yaml"
VENV="$REPO/.venv"
CAPEVOLVE="$VENV/bin/cap-evolve"
OPTIMIZER_CLAUDE_DIR="$PROJECT/optimizer-claude"
GLM_MODEL="rits/zai-org/glm-5-3"
GATEWAY_URL="${ANTHROPIC_BASE_URL:-https://ai-gateway-unified-ai-gateway-dogfood.dogfood-us-south-1-bxf-4x-f196230f74f7ff44a5b4eeb1003c5bd5-0000.us-south.containers.appdomain.cloud}"

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

HARBOR_MODEL_NAME="${HARBOR_MODEL:-$GLM_MODEL}"
OPTIMIZER_MODEL_NAME="${OPTIMIZER_MODEL:-$GLM_MODEL}"

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "error: set ANTHROPIC_API_KEY (AI gateway key) before running" >&2
  exit 1
fi
if [ ! -f "$OPTIMIZER_CLAUDE_DIR/settings.json" ]; then
  echo "error: missing $OPTIMIZER_CLAUDE_DIR/settings.json (GLM behavesAs)" >&2
  exit 1
fi

# Isolated Claude config: behavesAs for GLM. Seed onboarding so -p does not hang.
CLAUDE_JSON="$OPTIMIZER_CLAUDE_DIR/.claude.json"
if [ ! -f "$CLAUDE_JSON" ] || ! grep -q '"hasCompletedOnboarding": true' "$CLAUDE_JSON" 2>/dev/null; then
  printf '%s\n' '{"hasCompletedOnboarding":true,"migrationVersion":14}' > "$CLAUDE_JSON"
fi

# --- Harbor (evals on OpenShift) -------------------------------------------
TASK_IDS_FILE="${HARBOR_TASK_IDS_FILE:-$PROJECT/adapters/task_ids_pilot.txt}"
RUN_TS="${RUN_TS:-swebench-pilot}"

export HARBOR_BIN="$HARBOR"
export HARBOR_DATASET="${HARBOR_DATASET:-swe-bench/swe-bench-verified}"
export HARBOR_AGENT="${HARBOR_AGENT:-claude-code}"
export HARBOR_MODEL="$HARBOR_MODEL_NAME"
export HARBOR_PARALLEL="${HARBOR_PARALLEL:-16}"
export HARBOR_TIMEOUT="${HARBOR_TIMEOUT:-1800}"
export HARBOR_EXTRA_FLAGS="${HARBOR_EXTRA_FLAGS:--e openshift}"
export HARBOR_TASK_IDS="$(tr '\n' ',' < "$TASK_IDS_FILE" | sed 's/,$//')"
export HARBOR_AGENT_BASE_URL="$GATEWAY_URL"
export HARBOR_AGENT_API_KEY="$ANTHROPIC_API_KEY"

# --- Optimizer (local claude-code → GLM) -----------------------------------
unset CLAUDE_CODE_USE_VERTEX CLOUD_ML_REGION ANTHROPIC_VERTEX_PROJECT_ID
export ANTHROPIC_BASE_URL="$GATEWAY_URL"
export ANTHROPIC_API_KEY
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
export CLAUDE_CONFIG_DIR="$OPTIMIZER_CLAUDE_DIR"
export CAPEVOLVE_OPTIMIZER_MODEL="$OPTIMIZER_MODEL_NAME"

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

echo "==> Harbor:  $HARBOR ($HARBOR_AGENT @ $HARBOR_MODEL_NAME on OpenShift)"
echo "==> Optimizer: --model $OPTIMIZER_MODEL_NAME (CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR)"
echo "==> Tasks: $(echo "$HARBOR_TASK_IDS" | tr ',' '\n' | wc -l) from $(basename "$TASK_IDS_FILE")"
echo "==> Run dir: .capevolve/run_${RUN_TS}"

"$CAPEVOLVE" run \
  --spec "$SPEC" \
  --project "$PROJECT" \
  --run-ts "$RUN_TS" \
  --dashboard "${CAPEVOLVE_DASHBOARD:-auto}"
