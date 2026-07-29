#!/usr/bin/env python3
"""Standalone smoke test — verify rits.py's Vertex AI routing actually reaches
the Vertex API via litellm. Does NOT require tau2-bench to be installed.

Usage:
    export VERTEX_PROJECT=itpc-gcp-octo-eng-claude
    export VERTEX_LOCATION=global
    export TAU2_AGENT_MODEL=vertex_ai/claude-sonnet-4-5@20250929
    python3 test_vertex.py

Requires: `gcloud auth application-default login` (ADC) and litellm installed.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import rits  # sibling module — the same code path adapter.py uses


def main() -> int:
    model = rits.agent_model()
    if not model.lower().startswith("vertex_ai/"):
        print(
            f"TAU2_AGENT_MODEL={model!r} does not target Vertex AI "
            "(expected a 'vertex_ai/...' prefix). Set TAU2_AGENT_MODEL and retry.",
            file=sys.stderr,
        )
        return 2

    llm_args = rits.llm_args_for(model)
    print(f"model:    {model}")
    print(f"llm_args: {llm_args}")
    print("Calling litellm.completion() against Vertex AI ...")

    import litellm

    response = litellm.completion(
        model=model,
        messages=[{"role": "user", "content": "Say 'vertex ok' and nothing else."}],
        max_tokens=16,
        **llm_args,
    )

    text = response.choices[0].message.content
    print(f"response: {text!r}")

    if not text or "vertex ok" not in text.lower():
        print("WARNING: response did not contain the expected marker.", file=sys.stderr)
        return 1

    print("PASS — Vertex AI call succeeded.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
