import json
import time
from dataclasses import dataclass
from pathlib import Path
from typing import AsyncIterator

import httpx

from project import (
    load_project,
    project_context,
    project_default_model,
    read_guidelines,
    read_memory_index,
)
from tools.context import (
    reset_project_dir,
    reset_working_dir,
    set_project_dir,
    set_working_dir,
)
from tools.registry import ToolRegistry


@dataclass
class AgentConfig:
    ollama_host: str
    default_model: str
    system_prompt: str
    think: bool = False
    max_turns: int = 10
    keep_alive: str = "5m"


async def chat_stream(
    messages: list[dict],
    model: str | None,
    config: AgentConfig,
    registry: ToolRegistry,
    enabled_tools: list[str] | None = None,
    ollama_host: str | None = None,
    system_prompt: str | None = None,
    project_dir: str | None = None,
    working_dir: str | None = None,
) -> AsyncIterator[dict]:
    """Agentic loop:

    1. Call Ollama with the tool schemas.
    2. Stream text deltas to the client.
    3. If the model emits tool_calls, execute each, stream start/result events,
       append the results to the conversation, and loop back to step 1.
    4. When a turn produces no tool calls, emit message_end and stop.

    Project interpretation (Step 3): when `project_dir` is set, the project's
    `project.toml`/`guidelines.md` shape three things —
      • model: explicit `model` → project `[models].default` → global default,
      • prompt: base Alice (request override or shipped default) + guidelines,
      • tool scope: `working_dir` (the project folder, else ~/LookingGlass/Inbox)
        is published to tools via a contextvar for the duration of the request.
    Invariant #1 holds — a base system prompt is always present; guidelines are
    purely additive.
    """
    host = ollama_host or config.ollama_host

    project_cfg = load_project(project_dir)
    resolved_model = model or project_default_model(project_cfg) or config.default_model

    base_prompt = system_prompt if (system_prompt and system_prompt.strip()) else config.system_prompt

    # Output scope: explicit working_dir → project folder → independent Inbox.
    scope = working_dir or project_dir
    work_path = Path(scope).expanduser() if scope else Path.home() / "LookingGlass" / "Inbox"
    try:
        work_path.mkdir(parents=True, exist_ok=True)
    except Exception:
        pass

    # Prompt = base Alice (+ project context, when in a project) (+ guidelines).
    # All additive — Invariant #1 keeps a base prompt always present. The project
    # context's path is the live work_path (== tool scope), never a stored copy.
    parts = [base_prompt]
    if project_dir:
        ctx = project_context(project_cfg, str(work_path))
        if ctx:
            parts.append(ctx)
        # Passive recall: Alice always sees WHAT she's remembered (index only);
        # she pulls full bodies on demand via the recall_memory tool.
        mem_index = read_memory_index(project_dir)
        if mem_index:
            parts.append(
                "## Remembered notes (this project)\n"
                "You saved these notes in earlier conversations. Call `recall_memory` "
                "with a topic to read any of them in full.\n\n" + mem_index
            )
    guidelines = read_guidelines(project_dir)
    if guidelines:
        parts.append(guidelines)
    active_prompt = "\n\n---\n\n".join(parts)

    wd_token = set_working_dir(work_path)
    pd_token = set_project_dir(Path(project_dir).expanduser() if project_dir else None)

    full: list[dict] = [{"role": "system", "content": active_prompt}] + messages
    tool_schemas = registry.ollama_schemas(enabled_tools)

    total_in = 0
    total_out = 0

    try:
        async with httpx.AsyncClient(timeout=300.0) as client:
            for turn in range(config.max_turns):
                payload = {
                    "model": resolved_model,
                    "messages": full,
                    "stream": True,
                    "think": config.think,
                    # Bounds how long Ollama holds the model after we stop talking.
                    # Refreshed by any client, so a shared model isn't yanked early.
                    "keep_alive": config.keep_alive,
                }
                if tool_schemas:
                    payload["tools"] = tool_schemas

                assistant_content = ""
                tool_calls: list[dict] = []

                try:
                    async with client.stream("POST", f"{host}/api/chat", json=payload) as response:
                        if response.status_code >= 400:
                            # Surface Ollama's actual reason (model not found, OOM,
                            # bad request…) instead of an opaque status code. Must
                            # read the body inside the stream context.
                            body = await response.aread()
                            detail = body.decode("utf-8", "replace").strip()
                            msg = f"Ollama HTTP {response.status_code}"
                            if detail:
                                msg += f": {detail[:500]}"
                            yield {"type": "error", "message": msg}
                            return
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
    finally:
        reset_working_dir(wd_token)
        reset_project_dir(pd_token)


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
