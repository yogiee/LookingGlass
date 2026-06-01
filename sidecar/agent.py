import json
import time
from dataclasses import dataclass
from typing import AsyncIterator

import httpx

from tools.registry import ToolRegistry


@dataclass
class AgentConfig:
    ollama_host: str
    default_model: str
    system_prompt: str
    think: bool = False
    max_turns: int = 10


async def chat_stream(
    messages: list[dict],
    model: str,
    config: AgentConfig,
    registry: ToolRegistry,
    enabled_tools: list[str] | None = None,
    ollama_host: str | None = None,
    system_prompt: str | None = None,
) -> AsyncIterator[dict]:
    """Agentic loop:

    1. Call Ollama with the tool schemas.
    2. Stream text deltas to the client.
    3. If the model emits tool_calls, execute each, stream start/result events,
       append the results to the conversation, and loop back to step 1.
    4. When a turn produces no tool calls, emit message_end and stop.

    A non-empty `system_prompt` overrides the sidecar's default (the generic
    Alice that ships in prompts/alice.md). Either way a system prompt is always
    prepended — it's never absent.
    """
    host = ollama_host or config.ollama_host
    active_prompt = system_prompt if (system_prompt and system_prompt.strip()) else config.system_prompt
    full: list[dict] = [{"role": "system", "content": active_prompt}] + messages
    tool_schemas = registry.ollama_schemas(enabled_tools)

    total_in = 0
    total_out = 0

    async with httpx.AsyncClient(timeout=300.0) as client:
        for turn in range(config.max_turns):
            payload = {
                "model": model,
                "messages": full,
                "stream": True,
                "think": config.think,
            }
            if tool_schemas:
                payload["tools"] = tool_schemas

            assistant_content = ""
            tool_calls: list[dict] = []

            try:
                async with client.stream("POST", f"{host}/api/chat", json=payload) as response:
                    response.raise_for_status()
                    async for line in response.aiter_lines():
                        if not line.strip():
                            continue
                        try:
                            data = json.loads(line)
                        except json.JSONDecodeError:
                            continue

                        msg = data.get("message", {})
                        content = msg.get("content", "")
                        if content:
                            assistant_content += content
                            yield {"type": "content_delta", "text": content}

                        if msg.get("tool_calls"):
                            tool_calls.extend(msg["tool_calls"])

                        if data.get("done"):
                            total_in += data.get("prompt_eval_count", 0)
                            total_out += data.get("eval_count", 0)

            except httpx.ConnectError:
                yield {"type": "error", "message": f"Ollama not reachable at {host}"}
                return
            except httpx.HTTPStatusError as e:
                yield {"type": "error", "message": f"Ollama HTTP {e.response.status_code}"}
                return
            except Exception as e:
                yield {"type": "error", "message": f"{type(e).__name__}: {e}"}
                return

            # No tools requested this turn → the model is done talking.
            if not tool_calls:
                yield {
                    "type": "message_end",
                    "usage": {"input_tokens": total_in, "output_tokens": total_out},
                }
                return

            # Record the assistant's turn (content + the calls it wants to make).
            full.append({
                "role": "assistant",
                "content": assistant_content,
                "tool_calls": tool_calls,
            })

            # Execute each tool, streaming start/result, and feed results back.
            for i, tc in enumerate(tool_calls):
                fn = tc.get("function", {})
                name = fn.get("name", "")
                raw_args = fn.get("arguments", {})
                args = _coerce_args(raw_args)
                tc_id = f"tc_{turn}_{i}"

                yield {"type": "tool_call_start", "id": tc_id, "tool": name, "args": args}

                start = time.monotonic()
                tool = registry.get(name)
                if tool is None:
                    result = {"success": False, "result": f"Unknown tool: {name}"}
                else:
                    try:
                        result = await tool.handler(args)
                    except Exception as e:
                        result = {"success": False, "result": f"{type(e).__name__}: {e}"}
                latency_ms = int((time.monotonic() - start) * 1000)

                yield {
                    "type": "tool_call_result",
                    "id": tc_id,
                    "tool": name,
                    "success": result.get("success", False),
                    "result": result.get("result", ""),
                    "latency_ms": latency_ms,
                }

                full.append({
                    "role": "tool",
                    "content": result.get("result", ""),
                    "tool_name": name,
                })

        # Hit the turn ceiling without the model settling.
        yield {
            "type": "message_end",
            "usage": {"input_tokens": total_in, "output_tokens": total_out},
        }


def _coerce_args(raw) -> dict:
    """Ollama returns tool arguments as a dict, but some models emit a JSON
    string. Normalise to a dict either way."""
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        try:
            parsed = json.loads(raw)
            return parsed if isinstance(parsed, dict) else {}
        except json.JSONDecodeError:
            return {}
    return {}
