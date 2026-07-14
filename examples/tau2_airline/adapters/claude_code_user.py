"""tau2 UserSimulator backed by headless Claude Code CLI (``claude -p``).

Registered as ``claude_code_user`` for use when ``TAU2_AGENT_MODE=claude_code``.
"""

from __future__ import annotations

import os

from tau2.data_model.message import (
    AssistantMessage,
    MultiToolMessage,
    ToolMessage,
    UserMessage,
)
from tau2.user.user_simulator import UserSimulator, UserState
from tau2.user.user_simulator_base import ValidUserInputMessage

import claude_code_runner


class ClaudeCodeUserSimulator(UserSimulator):
    """User simulator that calls ``claude -p`` each turn (no litellm/API)."""

    def _generate_next_message(
        self, message: ValidUserInputMessage, state: UserState
    ) -> UserMessage:
        if isinstance(message, AssistantMessage) and message.is_audio:
            raise ValueError(
                "Assistant message cannot be audio. Use VoiceUserSimulator instead."
            )

        if isinstance(message, MultiToolMessage):
            state.messages.extend(message.tool_messages)
        elif isinstance(message, ToolMessage):
            state.messages.append(message)
        elif message.has_content() or message.is_tool_call():
            state.messages.append(message)

        system_prompt = (
            state.system_messages[0].content
            if state.system_messages
            else self.system_prompt
        )
        conv_messages = state.system_messages + state.flip_roles()

        result = claude_code_runner.invoke_user(
            system_prompt=system_prompt,
            messages=conv_messages,
            model=self.llm,
            max_turns=int(os.environ.get("TAU2_CLAUDE_USER_MAX_TURNS", "1")),
        )

        content = result.get("content") or ""
        if result.get("error") and not content.startswith("["):
            content = f"[infrastructure error] {result['error']}"

        return UserMessage(
            role="user",
            content=content,
            cost=float(result.get("cost_usd") or 0.0),
        )


def create_claude_code_user(llm, instructions=None, tools=None, llm_args=None, **kwargs):
    """Factory-compatible constructor for tau2 ``build_user``."""
    return ClaudeCodeUserSimulator(
        llm=llm,
        instructions=instructions,
        tools=tools,
        llm_args=llm_args or {},
        persona_config=kwargs.get("persona_config"),
    )
