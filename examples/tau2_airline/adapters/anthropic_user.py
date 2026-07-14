"""LiteLLM wiring for tau2 user simulator via Anthropic API (no RITS).

Used when ``TAU2_AGENT_MODE=claude_code`` and RITS credentials are unavailable.
The eval agent uses Claude Code CLI; the user simulator stays on a cheap API model.
"""

from __future__ import annotations

import os
from pathlib import Path

# Default user-sim model (override with TAU2_USER_MODEL).
DEFAULT_USER_MODEL = "anthropic/claude-haiku-4-5"


def _load_env() -> None:
    """Load repo-root .env without overwriting existing env vars."""
    here = Path(__file__).resolve()
    for parent in [here.parent, *here.parents]:
        env = parent / ".env"
        if env.exists():
            try:
                for raw in env.read_text(encoding="utf-8").splitlines():
                    line = raw.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    key, _, val = line.partition("=")
                    key = key.strip()
                    val = val.strip().strip('"').strip("'")
                    if key:
                        os.environ.setdefault(key, val)
            except Exception:
                pass
            break


def user_model() -> str:
    """Return the litellm model string for the user simulator."""
    _load_env()
    return os.environ.get("TAU2_USER_MODEL", DEFAULT_USER_MODEL)


def llm_args() -> dict:
    """Return litellm kwargs for the user simulator (lazy; no network at import)."""
    _load_env()
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        raise RuntimeError(
            "ANTHROPIC_API_KEY not set. Required for user simulator when "
            "TAU2_AGENT_MODE=claude_code without RITS. Put it in repo-root .env."
        )
    args: dict = {"api_key": key, "temperature": 0.0}
    base = os.environ.get("ANTHROPIC_BASE_URL")
    if base:
        args["api_base"] = base
    return args


def available() -> bool:
    """True when Anthropic credentials are present (for mode selection)."""
    _load_env()
    return bool(os.environ.get("ANTHROPIC_API_KEY"))
