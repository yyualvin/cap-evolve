"""Google Vertex AI wiring for tau2 user simulator (Claude via Vertex partner models).

Use when Claude Code is authenticated through Vertex (not ANTHROPIC_API_KEY).
Auth is via Application Default Credentials — typically:

  export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
  # or: gcloud auth application-default login

Project/region env vars (match Claude Code Vertex setups):

  ANTHROPIC_VERTEX_PROJECT_ID=...   # or VERTEXAI_PROJECT
  CLOUD_ML_REGION=global            # or VERTEXAI_LOCATION
"""

from __future__ import annotations

import os
from pathlib import Path

# Cheap default for user-sim on Vertex (override with TAU2_USER_MODEL).
DEFAULT_USER_MODEL = "vertex_ai/claude-haiku-4-5"


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


def vertex_project() -> str | None:
    _load_env()
    return (
        os.environ.get("ANTHROPIC_VERTEX_PROJECT_ID")
        or os.environ.get("VERTEXAI_PROJECT")
        or os.environ.get("VERTEX_PROJECT")
    )


def vertex_location() -> str:
    _load_env()
    return (
        os.environ.get("CLOUD_ML_REGION")
        or os.environ.get("VERTEXAI_LOCATION")
        or os.environ.get("VERTEX_LOCATION")
        or "global"
    )


def available() -> bool:
    """True when a Vertex project id is configured (ADC provides auth)."""
    return bool(vertex_project())


def user_model() -> str:
    _load_env()
    model = os.environ.get("TAU2_USER_MODEL")
    if model:
        return model if model.startswith("vertex_ai/") else f"vertex_ai/{model}"
    return DEFAULT_USER_MODEL


def llm_args() -> dict:
    """Return litellm kwargs for Vertex Claude user simulator."""
    project = vertex_project()
    if not project:
        raise RuntimeError(
            "Vertex project not set. For Claude Code on Google Vertex, add to repo-root .env:\n"
            "  ANTHROPIC_VERTEX_PROJECT_ID=<your-gcp-project>\n"
            "  CLOUD_ML_REGION=global   # or your region\n"
            "  GOOGLE_APPLICATION_CREDENTIALS=/path/to/sa.json  # or use gcloud ADC\n"
            "Or set TAU2_USER_MODEL + RITS_API_KEY if you prefer RITS for user-sim only."
        )
    return {
        "vertex_project": project,
        "vertex_location": vertex_location(),
        "temperature": 0.0,
    }
