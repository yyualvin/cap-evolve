#!/usr/bin/env bash
# Smoke: Claude Code CLI as tau2 eval agent + claude-code optimizer.
# Prereq: bash examples/tau2_airline/setup.sh
set -uo pipefail
EX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$EX_DIR/../.." && pwd)"
PROJECT="$REPO/.capevolve/project"

export PYTHONPATH="$PROJECT/adapters"
export CAPEVOLVE_SKILLS_DIR="$REPO/skills"
export TAU2_AGENT_MODE=claude_code
export TAU2_MAX_CONCURRENCY="${TAU2_MAX_CONCURRENCY:-1}"
export TAU2_CLAUDE_AGENT_MODEL="${TAU2_CLAUDE_AGENT_MODEL:-claude-sonnet-4-6}"
export TAU2_LLM_TIMEOUT="${TAU2_LLM_TIMEOUT:-300}"

if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: claude CLI not on PATH (required for TAU2_AGENT_MODE=claude_code)" >&2
  exit 1
fi

echo "tau2 agent: claude_code_agent @ $TAU2_CLAUDE_AGENT_MODEL (claude -p per turn)"
echo "optimizer:  claude-code @ claude-opus-4-6 | 1 iter · 2 tasks · 1 trial · concurrency $TAU2_MAX_CONCURRENCY"

"$REPO/.venv/bin/cap-evolve" run \
  --spec "$PROJECT/capevolve.claude-agent.smoke.yaml" --project "$PROJECT" \
  --run-ts smoke-claude-agent --dashboard "${CAPEVOLVE_DASHBOARD:-off}"
