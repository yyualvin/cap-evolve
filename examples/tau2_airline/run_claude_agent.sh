#!/usr/bin/env bash
# Full cap-evolve run on tau2-bench airline with Claude Code CLI as eval agent + user sim.
# Prereq: bash examples/tau2_airline/setup.sh  (installs deps + scaffolds + checks).
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
export TAU2_LLM_TIMEOUT="${TAU2_LLM_TIMEOUT:-240}"
export TAU2_LLM_RETRIES="${TAU2_LLM_RETRIES:-2}"
export TAU2_INFRA_RETRIES="${TAU2_INFRA_RETRIES:-2}"

if ! command -v claude >/dev/null 2>&1 && [ -z "${CLAUDE_BIN:-}" ]; then
  echo "ERROR: claude CLI not on PATH. Install Claude Code or set CLAUDE_BIN." >&2
  exit 1
fi

echo "tau2-bench commit: $(cat "$EX_DIR/run_full/TAU2_COMMIT.txt" 2>/dev/null || echo '?')"
echo "eval: claude-code agent=$TAU2_CLAUDE_AGENT_MODEL user=$TAU2_CLAUDE_USER_MODEL | optimizer: claude-code"
echo "------ pre-run cost preview (spends nothing) ------"
"$REPO/.venv/bin/cap-evolve" estimate --spec "$PROJECT/capevolve.claude-agent.yaml" --project "$PROJECT"
echo "------ cap-evolve run (live dashboard) ------"
"$REPO/.venv/bin/cap-evolve" run \
  --spec "$PROJECT/capevolve.claude-agent.yaml" --project "$PROJECT" \
  --run-ts claude-agent --dashboard "${CAPEVOLVE_DASHBOARD:-auto}"
