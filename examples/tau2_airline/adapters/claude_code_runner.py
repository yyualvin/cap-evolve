"""Headless Claude Code CLI wrapper for tau2 eval-agent and user-simulator turns.

Each turn spawns ``claude -p`` with a serialized conversation (+ tool schemas for
the agent) and parses structured JSON output. No Bash tools — callers must only
emit text or a single tool call per agent turn, or plain user text per user turn.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
from typing import Any

logger = logging.getLogger(__name__)

# tau2 mutual-exclusion rule: message OR tool_call, never both.
RESPONSE_JSON_SCHEMA = json.dumps(
    {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["message", "tool_call"]},
            "content": {"type": "string"},
            "tool_name": {"type": "string"},
            "arguments": {"type": "object"},
        },
        "required": ["action"],
        "additionalProperties": False,
    }
)

USER_JSON_SCHEMA = json.dumps(
    {
        "type": "object",
        "properties": {"content": {"type": "string"}},
        "required": ["content"],
        "additionalProperties": False,
    }
)

AGENT_INSTRUCTION = """
You are a customer service agent that helps the user according to the <policy> provided below.
In each turn you can either:
- Send a message to the user (action=message).
- Make a tool call (action=tool_call).
You cannot do both at the same time.

Try to be helpful and always follow the policy. Respond ONLY with valid JSON matching the schema.
""".strip()

USER_INSTRUCTION = """
You are simulating a customer in a conversation with a customer service agent.
Follow the scenario instructions in <system> and respond naturally as the user.
Respond ONLY with valid JSON: {"content": "your message to the agent"}.
When your goal is complete, include ###STOP### in your message.
""".strip()


def _serialize_message(msg: Any) -> str:
    """Best-effort serialization of a tau2 Message for the prompt."""
    if hasattr(msg, "model_dump"):
        d = msg.model_dump(mode="json")
    elif isinstance(msg, dict):
        d = msg
    else:
        return str(msg)

    role = d.get("role", "?")
    parts: list[str] = [f"[{role}]"]
    if d.get("content"):
        parts.append(str(d["content"]))
    for tc in d.get("tool_calls") or []:
        if isinstance(tc, dict):
            name = tc.get("name", "?")
            args = tc.get("arguments", {})
            parts.append(f"tool_call: {name}({json.dumps(args)})")
        else:
            parts.append(f"tool_call: {tc}")
    return "\n".join(parts)


def build_prompt(
    *,
    domain_policy: str,
    tools: list,
    messages: list,
) -> str:
    """Build the single-turn prompt for the eval agent ``claude -p`` call."""
    tool_schemas = []
    for t in tools:
        schema = getattr(t, "openai_schema", None)
        if schema is not None:
            tool_schemas.append(schema)
        elif hasattr(t, "name"):
            tool_schemas.append({"name": t.name})

    conv_lines = [_serialize_message(m) for m in messages]
    return (
        f"<instructions>\n{AGENT_INSTRUCTION}\n</instructions>\n"
        f"<policy>\n{domain_policy}\n</policy>\n"
        f"<tools>\n{json.dumps(tool_schemas, indent=2)}\n</tools>\n"
        f"<conversation>\n" + "\n---\n".join(conv_lines) + "\n</conversation>\n"
        "Respond with JSON: action=message and content=your reply, OR "
        "action=tool_call with tool_name and arguments (object). One action only."
    )


def build_user_prompt(*, system_prompt: str, messages: list) -> str:
    """Build the single-turn prompt for the user simulator ``claude -p`` call."""
    conv_lines = [_serialize_message(m) for m in messages]
    return (
        f"<instructions>\n{USER_INSTRUCTION}\n</instructions>\n"
        f"<system>\n{system_prompt}\n</system>\n"
        f"<conversation>\n" + "\n---\n".join(conv_lines) + "\n</conversation>\n"
        'Respond with JSON: {"content": "your reply as the user"}.'
    )


def _find_claude() -> str:
    claude = os.environ.get("CLAUDE_BIN") or shutil.which("claude")
    if not claude:
        raise RuntimeError(
            "claude CLI not found on PATH. Install Claude Code or set CLAUDE_BIN."
        )
    return claude


def _parse_cli_json(stdout: str) -> dict:
    """Parse Claude Code ``--output-format json`` stdout."""
    try:
        return json.loads(stdout)
    except json.JSONDecodeError:
        for line in reversed(stdout.strip().splitlines()):
            line = line.strip()
            if line.startswith("{"):
                try:
                    return json.loads(line)
                except json.JSONDecodeError:
                    continue
    raise ValueError(f"could not parse claude JSON output: {stdout[:500]!r}")


def _extract_structured(cli_result: dict) -> dict:
    """Pull the agent action dict from CLI JSON (structured_output or result)."""
    structured = cli_result.get("structured_output")
    if isinstance(structured, dict) and structured.get("action"):
        return structured

    result = cli_result.get("result")
    if isinstance(result, str) and result.strip():
        try:
            parsed = json.loads(result)
            if isinstance(parsed, dict) and parsed.get("action"):
                return parsed
        except json.JSONDecodeError:
            return {"action": "message", "content": result.strip()}

    if isinstance(result, dict) and result.get("action"):
        return result

    raise ValueError(f"no structured action in claude output: {cli_result!r}")


def _extract_user_content(cli_result: dict) -> str:
    """Pull user reply text from CLI JSON."""
    structured = cli_result.get("structured_output")
    if isinstance(structured, dict) and structured.get("content") is not None:
        return str(structured["content"])

    result = cli_result.get("result")
    if isinstance(result, str) and result.strip():
        try:
            parsed = json.loads(result)
            if isinstance(parsed, dict) and parsed.get("content") is not None:
                return str(parsed["content"])
        except json.JSONDecodeError:
            return result.strip()

    if isinstance(result, dict) and result.get("content") is not None:
        return str(result["content"])

    raise ValueError(f"no user content in claude output: {cli_result!r}")


def _run_claude(
    *,
    prompt: str,
    model: str,
    json_schema: str,
    max_turns: int,
    timeout_sec: int | None = None,
) -> dict:
    """Shared headless ``claude -p`` invocation."""
    claude = _find_claude()
    timeout = timeout_sec or int(os.environ.get("TAU2_CLAUDE_AGENT_TIMEOUT", "300"))

    cmd = [
        claude,
        "-p",
        prompt,
        "--permission-mode",
        "acceptEdits",
        "--model",
        model,
        "--output-format",
        "json",
        "--max-turns",
        str(max_turns),
        "--json-schema",
        json_schema,
    ]

    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=os.environ.copy(),
            check=False,
        )
    except subprocess.TimeoutExpired as e:
        return {
            "ok": False,
            "content": "[infrastructure error: claude -p timed out]",
            "cost_usd": 0.0,
            "error": f"timeout after {timeout}s: {e}",
            "stdout": "",
        }
    except OSError as e:
        return {
            "ok": False,
            "content": "[infrastructure error: claude -p failed to start]",
            "cost_usd": 0.0,
            "error": str(e),
            "stdout": "",
        }

    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "")[:800]
        logger.warning("claude -p failed rc=%s stderr=%s", proc.returncode, err)
        return {
            "ok": False,
            "content": "[infrastructure error: claude -p exited non-zero]",
            "cost_usd": 0.0,
            "error": err,
            "stdout": proc.stdout or "",
        }

    try:
        cli_result = _parse_cli_json(proc.stdout)
        cost = float(cli_result.get("total_cost_usd") or 0.0)
        return {
            "ok": True,
            "cli_result": cli_result,
            "cost_usd": cost,
            "error": None,
            "stdout": proc.stdout,
        }
    except (ValueError, TypeError, json.JSONDecodeError) as e:
        logger.warning("claude output parse error: %s stdout=%s", e, proc.stdout[:500])
        return {
            "ok": False,
            "content": "[infrastructure error: unparseable claude output]",
            "cost_usd": 0.0,
            "error": str(e),
            "stdout": proc.stdout or "",
        }


def invoke(
    *,
    domain_policy: str,
    tools: list,
    messages: list,
    model: str,
    max_turns: int = 3,
    timeout_sec: int | None = None,
) -> dict:
    """Run one eval-agent Claude Code turn."""
    prompt = build_prompt(domain_policy=domain_policy, tools=tools, messages=messages)
    raw = _run_claude(
        prompt=prompt,
        model=model,
        json_schema=RESPONSE_JSON_SCHEMA,
        max_turns=max_turns,
        timeout_sec=timeout_sec,
    )
    if not raw["ok"]:
        return {
            "type": "text",
            "content": raw["content"],
            "tool_name": None,
            "arguments": None,
            "cost_usd": raw["cost_usd"],
            "error": raw["error"],
        }

    try:
        structured = _extract_structured(raw["cli_result"])
    except ValueError as e:
        return {
            "type": "text",
            "content": "[infrastructure error: unparseable claude output]",
            "tool_name": None,
            "arguments": None,
            "cost_usd": raw["cost_usd"],
            "error": str(e),
        }

    action = structured.get("action")
    if action == "tool_call":
        args = structured.get("arguments") or {}
        if isinstance(args, str):
            try:
                args = json.loads(args)
            except json.JSONDecodeError:
                args = {}
        if not isinstance(args, dict):
            args = {}
        return {
            "type": "tool_call",
            "content": None,
            "tool_name": str(structured.get("tool_name") or ""),
            "arguments": args,
            "cost_usd": raw["cost_usd"],
            "error": None,
        }

    return {
        "type": "text",
        "content": str(structured.get("content") or ""),
        "tool_name": None,
        "arguments": None,
        "cost_usd": raw["cost_usd"],
        "error": None,
    }


def invoke_user(
    *,
    system_prompt: str,
    messages: list,
    model: str,
    max_turns: int = 1,
    timeout_sec: int | None = None,
) -> dict:
    """Run one user-simulator Claude Code turn."""
    prompt = build_user_prompt(system_prompt=system_prompt, messages=messages)
    raw = _run_claude(
        prompt=prompt,
        model=model,
        json_schema=USER_JSON_SCHEMA,
        max_turns=max_turns,
        timeout_sec=timeout_sec,
    )
    if not raw["ok"]:
        return {
            "content": raw["content"],
            "cost_usd": raw["cost_usd"],
            "error": raw["error"],
        }

    try:
        content = _extract_user_content(raw["cli_result"])
    except ValueError as e:
        return {
            "content": "[infrastructure error: unparseable claude output]",
            "cost_usd": raw["cost_usd"],
            "error": str(e),
        }

    return {"content": content, "cost_usd": raw["cost_usd"], "error": None}
