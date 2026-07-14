#!/usr/bin/env bash
# Cheap 2-task smoke: Claude Code CLI as eval agent + user sim + claude-code optimizer.
# Prereq: bash examples/tau2_airline/setup.sh
set -uo pipefail
EX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$EX_DIR/../.." && pwd)"
PROJECT="$REPO/.capevolve/project"

export PYTHONPATH="$PROJECT/adapters"
export CAPEVOLVE_SKILLS_DIR="$REPO/skills"
export TAU2_AGENT_MODE=claude_code
export TAU2_CLAUDE_AGENT_MODEL="${TAU2_CLAUDE_AGENT_MODEL:-claude-haiku-4-5}"
export TAU2_CLAUDE_USER_MODEL="${TAU2_CLAUDE_USER_MODEL:-claude-haiku-4-5}"
export TAU2_MAX_CONCURRENCY="${TAU2_MAX_CONCURRENCY:-2}"
export TAU2_LLM_TIMEOUT="${TAU2_LLM_TIMEOUT:-120}"

if ! command -v claude >/dev/null 2>&1 && [ -z "${CLAUDE_BIN:-}" ]; then
  echo "ERROR: claude CLI not on PATH. Install Claude Code or set CLAUDE_BIN." >&2
  exit 1
fi

"$REPO/.venv/bin/cap-evolve" run \
  --spec "$PROJECT/capevolve.claude-agent.smoke.yaml" --project "$PROJECT" \
  --run-ts smoke-claude-agent --dashboard "${CAPEVOLVE_DASHBOARD:-off}"
