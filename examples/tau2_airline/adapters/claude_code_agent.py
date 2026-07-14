"""tau2 HalfDuplexAgent backed by headless Claude Code CLI (``claude -p``).

Registered as ``claude_code_agent`` for use when ``TAU2_AGENT_MODE=claude_code``.
"""

from __future__ import annotations

import os
import uuid
from typing import List, Optional

from pydantic import BaseModel

from tau2.agent.base_agent import (
    HalfDuplexAgent,
    ValidAgentInputMessage,
    is_valid_agent_history_message,
)
from tau2.data_model.message import (
    APICompatibleMessage,
    AssistantMessage,
    Message,
    MultiToolMessage,
    SystemMessage,
    ToolCall,
    UserMessage,
)
from tau2.environment.tool import Tool

import claude_code_runner

AGENT_INSTRUCTION = claude_code_runner.AGENT_INSTRUCTION

SYSTEM_PROMPT = """
<instructions>
{agent_instruction}
</instructions>
<policy>
{domain_policy}
</policy>
""".strip()


class ClaudeCodeAgentState(BaseModel):
    """Conversation state for the Claude Code eval agent."""

    system_messages: list[SystemMessage]
    messages: list[APICompatibleMessage]
    cumulative_cost_usd: float = 0.0


class ClaudeCodeAgent(HalfDuplexAgent[ClaudeCodeAgentState]):
    """Turn-based agent that calls ``claude -p`` each step."""

    def __init__(
        self,
        tools: List[Tool],
        domain_policy: str,
        model: str = "claude-haiku-4-5",
        max_turns_per_step: int = 3,
    ):
        super().__init__(tools=tools, domain_policy=domain_policy)
        self.model = model
        self.max_turns_per_step = max_turns_per_step

    @property
    def system_prompt(self) -> str:
        return SYSTEM_PROMPT.format(
            domain_policy=self.domain_policy,
            agent_instruction=AGENT_INSTRUCTION,
        )

    def get_init_state(
        self, message_history: Optional[list[Message]] = None
    ) -> ClaudeCodeAgentState:
        if message_history is None:
            message_history = []
        assert all(is_valid_agent_history_message(m) for m in message_history), (
            "Message history must contain only AssistantMessage, UserMessage, "
            "or ToolMessage to Agent."
        )
        return ClaudeCodeAgentState(
            system_messages=[
                SystemMessage(role="system", content=self.system_prompt)
            ],
            messages=list(message_history),
        )

    def generate_next_message(
        self, message: ValidAgentInputMessage, state: ClaudeCodeAgentState
    ) -> tuple[AssistantMessage, ClaudeCodeAgentState]:
        if isinstance(message, UserMessage) and message.is_audio:
            raise ValueError("User message cannot be audio. Use VoiceLLMAgent instead.")
        if isinstance(message, MultiToolMessage):
            state.messages.extend(message.tool_messages)
        else:
            state.messages.append(message)

        all_messages = state.system_messages + state.messages
        result = claude_code_runner.invoke(
            domain_policy=self.domain_policy,
            tools=self.tools,
            messages=all_messages,
            model=self.model,
            max_turns=self.max_turns_per_step,
        )

        cost = float(result.get("cost_usd") or 0.0)
        state.cumulative_cost_usd += cost

        if result.get("type") == "tool_call" and result.get("tool_name"):
            tool_call = ToolCall(
                id=f"cc_{uuid.uuid4().hex[:8]}",
                name=result["tool_name"],
                arguments=result.get("arguments") or {},
                requestor="assistant",
            )
            assistant_message = AssistantMessage.text(
                content=None,
                tool_calls=[tool_call],
                cost=cost,
            )
        else:
            content = result.get("content") or ""
            if result.get("error") and not content.startswith("["):
                content = f"[infrastructure error] {result['error']}"
            assistant_message = AssistantMessage.text(content=content, cost=cost)

        state.messages.append(assistant_message)
        return assistant_message, state


def create_claude_code_agent(tools, domain_policy, **kwargs):
    """Factory for tau2 registry (``registry.register_agent_factory``)."""
    model = (
        kwargs.get("llm")
        or os.environ.get("TAU2_CLAUDE_AGENT_MODEL", "claude-haiku-4-5")
    )
    max_turns = int(
        os.environ.get(
            "TAU2_CLAUDE_AGENT_MAX_TURNS",
            str(kwargs.get("max_turns_per_step", 3)),
        )
    )
    return ClaudeCodeAgent(
        tools=tools,
        domain_policy=domain_policy,
        model=model,
        max_turns_per_step=max_turns,
    )
