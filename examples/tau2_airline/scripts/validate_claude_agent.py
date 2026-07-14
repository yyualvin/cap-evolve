#!/usr/bin/env python3
"""Standalone gate: run one airline task with claude_code_agent before cap-evolve.

Usage (from repo root, after setup.sh):

    export TAU2_AGENT_MODE=claude_code
    export TAU2_MAX_CONCURRENCY=1
    export TAU2_CLAUDE_AGENT_MODEL=claude-sonnet-4-6
    PYTHONPATH=.capevolve/project/adapters .venv/bin/python \
        examples/tau2_airline/scripts/validate_claude_agent.py

Requires: tau2-bench installed, ``claude`` on PATH, ANTHROPIC_API_KEY (or login).
Optional: RITS_API_KEY for cheaper user simulator.
"""

from __future__ import annotations

import contextlib
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
ADAPTERS = REPO / ".capevolve" / "project" / "adapters"
if not ADAPTERS.is_dir():
    ADAPTERS = Path(__file__).resolve().parents[1] / "adapters"

sys.path.insert(0, str(ADAPTERS))

os.environ.setdefault("TAU2_AGENT_MODE", "claude_code")
os.environ.setdefault("TAU2_MAX_CONCURRENCY", "1")
os.environ.setdefault("TAU2_CLAUDE_AGENT_MODEL", "claude-sonnet-4-6")


def main() -> int:
    from claude_code_agent import create_claude_code_agent
    from tau2.data_model.simulation import TextRunConfig
    from tau2.registry import registry
    from tau2.runner import get_tasks, run_single_task

    import anthropic_user
    import rits

    registry.register_agent_factory(create_claude_code_agent, "claude_code_agent")

    agent_model = os.environ.get("TAU2_CLAUDE_AGENT_MODEL", "claude-sonnet-4-6")
    try:
        llm_user = rits.LITELLM_MODEL
        llm_args_user = rits.llm_args()
        user_src = "RITS"
    except Exception:
        try:
            import vertex_llm

            if vertex_llm.available():
                llm_user = vertex_llm.user_model()
                llm_args_user = vertex_llm.llm_args()
                user_src = "Vertex"
            else:
                raise RuntimeError("no vertex")
        except Exception:
            llm_user = anthropic_user.user_model()
            llm_args_user = anthropic_user.llm_args()
            user_src = "Anthropic API"

    task_id = os.environ.get("CAPEVOLVE_TAU2_TASK_IDS", "0").split(",")[0].strip()
    tasks = get_tasks("airline", task_ids=[task_id])
    if not tasks:
        print(f"ERROR: no airline task with id {task_id!r}", file=sys.stderr)
        return 1

    config = TextRunConfig(
        domain="airline",
        agent="claude_code_agent",
        llm_agent=agent_model,
        llm_args_agent={},
        user="user_simulator",
        llm_user=llm_user,
        llm_args_user=dict(llm_args_user),
        max_concurrency=1,
        max_steps=100,
        max_errors=10,
        seed=42,
    )

    print(f"Validating claude_code_agent on airline task {task_id!r}")
    print(f"  agent model: {agent_model}")
    print(f"  user sim:    {llm_user} ({user_src})")

    with contextlib.redirect_stdout(sys.stderr):
        result = run_single_task(config, tasks[0], seed=42)

    reward = 0.0
    if result.reward_info and result.reward_info.reward is not None:
        reward = float(result.reward_info.reward)

    n_msgs = len(result.messages) if result.messages else 0
    print(f"\nResult:")
    print(f"  task_id:     {result.task_id}")
    print(f"  reward:      {reward:.3f}")
    print(f"  messages:    {n_msgs}")
    print(f"  agent_cost:  ${result.agent_cost or 0:.4f}")
    print(f"  termination: {result.termination_reason}")

    if result.termination_reason and "INFRASTRUCTURE" in str(result.termination_reason):
        print("\nFAIL: infrastructure termination", file=sys.stderr)
        return 1

    if reward <= 0.0:
        print("\nWARN: reward is 0 — check trajectories; may still be a valid run.", file=sys.stderr)

    print("\nOK: claude_code_agent completed one simulation.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
