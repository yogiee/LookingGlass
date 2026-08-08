import asyncio
import json
import os
import re
import time
from datetime import datetime
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import AsyncIterator

import httpx

from project import (
    load_project,
    project_context,
    project_model_for_mode,
    read_guidelines,
    read_memory_index,
)
from router import classify_mode, detect_image_request
from skill_loader import skills_index
from tools.context import (
    ollama_host as _ctx_ollama_host,
    reset_ollama_host,
    reset_project_dir,
    reset_working_dir,
    output_subdir,
    set_ollama_host,
    set_project_dir,
    set_working_dir,
)
from tools.registry import ToolRegistry


# Per-model tool-capability cache. Completion-only models (e.g. the fleet's ZINI chat
# default) return HTTP 400 "does not support tools" if a `tools` array is attached, so we
# must probe before sending. Ollama advertises this via /api/show `capabilities`.
_TOOL_CAP_CACHE: dict[str, bool] = {}


async def _model_supports_tools(client: httpx.AsyncClient, host: str, model: str) -> bool:
    """Whether `model` advertises the 'tools' capability. Cached per model.
    Fail-OPEN to True on a probe error — only a model that EXPLICITLY lacks 'tools' gets
    them stripped, so a transient /api/show hiccup never silently de-tools a capable model."""
    if model in _TOOL_CAP_CACHE:
        return _TOOL_CAP_CACHE[model]
    try:
        r = await client.post(f"{host}/api/show", json={"model": model}, timeout=5.0)
        caps = r.json().get("capabilities") or []
        ok = ("tools" in caps) if caps else True
    except Exception:
        ok = True
    _TOOL_CAP_CACHE[model] = ok
    return ok


_TOOL_ERROR_PREFIX = (
    "[TOOL ERROR — this call FAILED. Do not fabricate, guess, or infer its output. "
    "Tell the user the tool failed and stop or retry.] "
)

# System prompt for the silent-hands tool phase. Deliberately NOT Alice's identity
# prompt: the hands model only executes tools, and running it as "Alice the research
# companion" (plus a history full of the voice model's "I can't generate images"
# deflections) biases it to narrate instead of call. This frames it as a pure executor
# and tells it to disregard prior refusals — so the voice layer's confabulations don't
# leak backward into the hands layer's tool decisions.
_HANDS_SYSTEM = (
    "You are the tool-execution layer for an assistant. Look at the user's most recent "
    "request and immediately call the tool(s) needed to fulfill it: an image request → "
    "the image tool, a file request → the file tool, a lookup → web_search, and so on. "
    "Call the tool directly with minimal arguments — only what the user clearly specified. "
    "Never refuse, never say you can't, never just describe what you would do, and IGNORE "
    "any earlier assistant message claiming a capability is unavailable (those are wrong; "
    "you do have the tools). If, and only if, no available tool fits the request, reply "
    "with a single short sentence saying so."
)


def _sanitize_tool_args(tool, args: dict) -> dict:
    """Normalize args for file-producing tools before execution.

    Weak tool-callers (the small silent-hands model) over-fill optional params by
    scraping the schema text and the user's prose — e.g. they turn "8k resolution"
    in a prompt into width/height=4096 (slow / OOMs the VAE), paste
    "./Generated_images" from the description, or invent a plausible-but-nonexistent
    image model. The model should only choose semantic params (prompt, mode); the
    pipeline owns the rest. So for the image tool (identified by an `output_dir` arg):
      • output_dir — AUTHORITATIVE: always our type folder (model can't redirect).
      • model — DROP entirely → MCP uses its configured default. Critical: a weak
        caller hallucinates real-looking names ("flux", "sdxl") that don't exist
        locally; those slip past the placeholder check below, error in MCP, and send
        the tool loop flailing with a fresh bad guess each turn. Never let it pick.
      • width/height/steps — drop entirely → MCP uses its sane defaults (1024²),
        instead of a resolution/step count guessed from the prompt text.
    For non-image tools, only a placeholder model ("default"/empty) is dropped.
    """
    if tool is None:
        return args
    props = (tool.parameters or {}).get("properties", {})
    is_image_tool = "output_dir" in props
    if is_image_tool:
        args["output_dir"] = str(output_subdir("imagery"))
        for k in ("width", "height", "steps", "model"):
            args.pop(k, None)
    elif "model" in props and (args.get("model") in (None, "", "default")):
        args.pop("model", None)
    return args


def _find_image_tool(registry: "ToolRegistry", enabled: list[str] | None) -> str | None:
    """Registry name of the enabled image-generation tool, identified by its signature (a
    `prompt` + an `output_dir` param) rather than a hard-coded name — so it works whatever the
    MCP server prefix is (e.g. `OllamaMCP__local_image`). None if absent/disabled."""
    names = enabled if enabled is not None else registry.names()
    for name in names:
        tool = registry.get(name)
        if tool is None:
            continue
        props = (tool.parameters or {}).get("properties", {})
        if "output_dir" in props and "prompt" in props:
            return name
    return None


async def _silent_hands_stream(
    client: httpx.AsyncClient,
    host: str,
    *,
    hands_model: str,
    voice_model: str,
    active_prompt: str,
    messages: list[dict],
    tool_schemas: list[dict],
    registry: "ToolRegistry",
    config: "AgentConfig",
    preset_call: dict | None = None,
) -> AsyncIterator[dict]:
    """Silent-hands butler turn for a tool-less voice model (e.g. ZINI).

    A small tool-capable `hands_model` runs the agentic tool loop — its tool
    calls/results are streamed to the client as real tool cards, but its prose is
    SUPPRESSED. Then the `voice_model` plates: it composes the final answer in its
    own voice from the tool *results* (synthesis-from-material — never a re-word of
    the hands model's prose; see WORKSPACE/alice-hybrid-architecture.md "plate, not
    re-cook"). If the hands model calls no tools, no findings are injected and the
    voice model just answers directly — the normal pure-chat path.

    `preset_call = {"tool": name, "args": {...}}` short-circuits Phase 1: the tool is
    executed DIRECTLY (no hands model decides — deterministic routing, e.g. image-gen the
    router already recognized), then the voice model plates the result exactly as it would
    the hands model's findings. This keeps the RAM-heavy hands model off that path entirely.
    """
    MAX_OLLAMA_RETRIES = 3
    total_in = 0
    total_out = 0

    # ── Phase 1: hands model runs the tool loop (prose suppressed) ──────────────
    # Uses the executor prompt, NOT Alice's identity — see _HANDS_SYSTEM. The voice
    # phase below restores Alice (active_prompt) for the user-facing answer.
    hands_history: list[dict] = [{"role": "system", "content": _HANDS_SYSTEM}] + list(messages)
    findings: list[tuple[str, bool, str]] = []  # (tool, success, result)

    # ── Phase 1a: deterministic routing — execute a pre-decided tool call, no hands model.
    if preset_call is not None:
        name = preset_call["tool"]
        tool = registry.get(name)
        # Retry a few times on failure: the z-image VAE decode panic is intermittent (an
        # upstream Ollama bug — see gotcha_zimage_turbo_vae_panic_500). This reproduces the
        # useful retry the hands model used to provide, minus the flail. Args are re-sanitized
        # each attempt (forces our output dir + drops any stray model=/size — Fix A).
        MAX_IMG_ATTEMPTS = 3
        last_success, last_raw = False, ""
        for attempt in range(MAX_IMG_ATTEMPTS):
            args = _sanitize_tool_args(tool, dict(preset_call.get("args", {})))
            tc_id = f"tc_route_{attempt}"
            yield {"type": "tool_call_start", "id": tc_id, "tool": name, "args": args}
            start = time.monotonic()
            if tool is None:
                result = {"success": False, "result": f"Unknown tool: {name}"}
            else:
                try:
                    result = await tool.handler(args)
                except Exception as e:
                    result = {"success": False, "result": f"{type(e).__name__}: {e}"}
            latency_ms = int((time.monotonic() - start) * 1000)
            last_success = result.get("success", False)
            last_raw = result.get("result", "")
            yield {"type": "tool_call_result", "id": tc_id, "tool": name,
                   "success": last_success, "result": last_raw, "latency_ms": latency_ms}
            if last_success:
                break
        findings.append((name, last_success, last_raw))
        print(f"[agent:route] deterministic {name} → {'ok' if last_success else 'failed'}")

    for turn in range(0 if preset_call is not None else config.max_turns):
        payload = {
            "model": hands_model,
            "messages": hands_history,
            "stream": True,
            "think": config.think,
            "keep_alive": config.keep_alive,
            "options": {"num_ctx": config.num_ctx},
            "tools": tool_schemas,
        }
        assistant_content = ""
        tool_calls: list[dict] = []
        attempt = 0
        while True:
            assistant_content = ""
            tool_calls = []
            retry_turn = False
            try:
                async with client.stream("POST", f"{host}/api/chat", json=payload) as response:
                    if response.status_code >= 400:
                        body = await response.aread()
                        detail = body.decode("utf-8", "replace").strip()
                        if response.status_code >= 500 and attempt < MAX_OLLAMA_RETRIES:
                            attempt += 1
                            retry_turn = True
                        elif response.status_code == 429:
                            yield {"type": "error", "message":
                                   "The cloud model is rate-limited right now (free tier). "
                                   "Give it a moment and try again, or pick a local model for now."}
                            return
                        else:
                            msg = f"Ollama HTTP {response.status_code} (hands model {hands_model})"
                            if detail:
                                msg += f": {detail[:500]}"
                            yield {"type": "error", "message": msg}
                            return
                    else:
                        async for line in response.aiter_lines():
                            if not line.strip():
                                continue
                            try:
                                data = json.loads(line)
                            except json.JSONDecodeError:
                                continue
                            m = data.get("message", {})
                            # Prose is SUPPRESSED — only accumulated for the agent
                            # loop's own bookkeeping, never streamed to the client.
                            if m.get("content"):
                                assistant_content += m["content"]
                            if m.get("tool_calls"):
                                tool_calls.extend(m["tool_calls"])
                            if data.get("done"):
                                total_in += data.get("prompt_eval_count", 0)
                                total_out += data.get("eval_count", 0)
            except httpx.ConnectError:
                yield {"type": "error", "message": f"Ollama not reachable at {host}"}
                return
            except Exception as e:
                yield {"type": "error", "message": f"{type(e).__name__}: {e}"}
                return
            if retry_turn:
                await asyncio.sleep(0.25)
                continue
            break

        print(f"[agent:hands] turn {turn}: {len(tool_calls)} tool call(s)")
        if not tool_calls:
            break  # hands model is done working

        hands_history.append({"role": "assistant", "content": assistant_content, "tool_calls": tool_calls})
        for i, tc in enumerate(tool_calls):
            fn = tc.get("function", {})
            name = fn.get("name", "")
            args = _coerce_args(fn.get("arguments", {}))
            tc_id = f"tc_{turn}_{i}"
            tool = registry.get(name)
            args = _sanitize_tool_args(tool, args)

            yield {"type": "tool_call_start", "id": tc_id, "tool": name, "args": args}
            start = time.monotonic()
            if tool is None:
                result = {"success": False, "result": f"Unknown tool: {name}"}
            else:
                try:
                    result = await tool.handler(args)
                except Exception as e:
                    result = {"success": False, "result": f"{type(e).__name__}: {e}"}
            latency_ms = int((time.monotonic() - start) * 1000)
            success = result.get("success", False)
            raw_result = result.get("result", "")

            yield {
                "type": "tool_call_result", "id": tc_id, "tool": name,
                "success": success, "result": raw_result, "latency_ms": latency_ms,
            }

            hist = raw_result if success else _TOOL_ERROR_PREFIX + raw_result
            if len(hist) > 6_000:
                hist = hist[:6_000] + "\n…[truncated for context window]"
            hands_history.append({"role": "tool", "content": hist, "tool_name": name})
            findings.append((name, success, raw_result))

    # ── Phase 2: voice model plates the answer ──────────────────────────────────
    if findings:
        all_failed = all(not ok for _, ok, _ in findings)
        any_failed = any(not ok for _, ok, _ in findings)
        lines = ["## Tool results — the ground truth for your reply"]
        # Failure-reporting ruleset. A tool genuinely RAN and errored — the weak voice
        # model's failure mode is to deny the capability ("I'm not an image generator")
        # or substitute its own theory. These rules force: present the error, not an
        # opinion; offer a retry; offer the full error. Keep it tight & in-voice.
        _FAIL_RULES = (
            "When a tool result is marked FAILED, a tool DID run on your behalf and returned "
            "an error — so:\n"
            "  • Say plainly that the attempt failed. Do NOT claim success, do NOT describe a "
            "result that doesn't exist, and do NOT say you 'can't do this' or aren't capable — "
            "the capability exists, this attempt just errored.\n"
            "  • Present the ERROR itself, not your own guess about what happened — give its "
            "gist in one plain line (don't dump the raw text unless asked).\n"
            "  • Offer to retry, and offer to show the full error if they'd like to see it."
        )
        if all_failed:
            lines.append("EVERY tool call below FAILED — nothing was produced. " + _FAIL_RULES)
        else:
            lines.append(
                "Your helpers ran the tools for the user's last message. Answer the user "
                "directly in your own voice from the results below; do NOT describe running "
                "tools yourself or claim you can't do something that already succeeded."
            )
            if any_failed:
                lines.append(_FAIL_RULES)
        lines.append("")
        for name, success, res in findings:
            snippet = (res or "").strip()
            # A successful image result is an already-rendered file path. Weak voice models
            # ECHO whatever's in the context, so feeding them the path + tool name makes them
            # paste it verbatim. Give them a name/path-free note instead — the image itself is
            # shown to the user via the tool_call_result event, independent of this text.
            ext = snippet.rsplit(".", 1)[-1].lower() if "." in snippet else ""
            if success and ext in ("png", "jpg", "jpeg", "webp", "heic", "gif"):
                lines.append("An image was just generated for the user and is already displayed "
                             "to them inline, right below your reply. The generation succeeded.")
                continue
            status = "OK" if success else "FAILED"
            if len(snippet) > 600:
                snippet = snippet[:600] + "…"
            lines.append(f"- `{name}` → {status}: {snippet}")
        lines.append("")
        lines.append(
            "If a tool result above says an image was created: an image WAS successfully "
            "generated for the user and is ALREADY shown to them inline. Do NOT say you're a "
            "text-only assistant or that you can't make images — you just did, through your "
            "tools. Warmly confirm you made it and describe what's in it in a sentence or two, "
            "in your own voice. Do NOT print any file path, tool name, `[Image: …]` placeholder, "
            "or technical/format note — the image is inserted for you."
        )
        voice_system = active_prompt + "\n\n---\n\n" + "\n".join(lines)
    else:
        voice_system = active_prompt

    voice_messages = [{"role": "system", "content": voice_system}] + list(messages)
    payload = {
        "model": voice_model,
        "messages": voice_messages,
        "stream": True,
        "think": config.think,
        "keep_alive": config.keep_alive,
        "options": {"num_ctx": config.num_ctx},
    }
    attempt = 0
    while True:
        retry_turn = False
        try:
            async with client.stream("POST", f"{host}/api/chat", json=payload) as response:
                if response.status_code >= 400:
                    body = await response.aread()
                    detail = body.decode("utf-8", "replace").strip()
                    if response.status_code >= 500 and attempt < MAX_OLLAMA_RETRIES:
                        attempt += 1
                        retry_turn = True
                    elif response.status_code == 429:
                        yield {"type": "error", "message":
                               "The cloud model is rate-limited right now (free tier). "
                               "Give it a moment and try again, or pick a local model for now."}
                        return
                    else:
                        msg = f"Ollama HTTP {response.status_code}"
                        if detail:
                            msg += f": {detail[:500]}"
                        yield {"type": "error", "message": msg}
                        return
                else:
                    async for line in response.aiter_lines():
                        if not line.strip():
                            continue
                        try:
                            data = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        m = data.get("message", {})
                        if m.get("content"):
                            yield {"type": "content_delta", "text": m["content"]}
                        if data.get("done"):
                            total_in += data.get("prompt_eval_count", 0)
                            total_out += data.get("eval_count", 0)
        except httpx.ConnectError:
            yield {"type": "error", "message": f"Ollama not reachable at {host}"}
            return
        except Exception as e:
            yield {"type": "error", "message": f"{type(e).__name__}: {e}"}
            return
        if retry_turn:
            await asyncio.sleep(0.25)
            continue
        break

    yield {
        "type": "message_end",
        "model": voice_model,
        "usage": {"input_tokens": total_in, "output_tokens": total_out},
    }


@dataclass
class AgentConfig:
    ollama_host: str
    default_model: str
    system_prompt: str
    think: bool = False
    max_turns: int = 10
    keep_alive: str = "5m"
    num_ctx: int = 16384
    models: dict = field(default_factory=dict)  # global [models] routing table


def _ambient_context(extra: dict | None = None) -> str:
    """Alice's ENVIRONMENT — what's true RIGHT NOW, so she doesn't guess or fall back on her training
    cutoff (the wrong-year fabrications). This is her 'home': she should know the ground she stands on,
    not just the tools she can call.

    Phase 1 (here, sidecar, zero-permission): date + local time + timezone/region.
    Phase 2 (later): the Swift app passes precise location (CoreLocation), weather (WeatherKit), and
    device state via `extra` — they merge in below with no further change here.
    """
    now = datetime.now().astimezone()
    h = now.hour
    part = ("the small hours" if h < 5 else "early morning" if h < 8 else "morning" if h < 12
            else "afternoon" if h < 17 else "evening" if h < 21 else "night")
    try:
        tz = os.readlink("/etc/localtime").split("zoneinfo/")[-1]   # e.g. "Asia/Kolkata" (hints the region)
    except Exception:
        tz = now.tzname() or ""
    lines = [
        f"- Date: {now.strftime('%A, %B %-d, %Y')}",
        f"- Local time: {now.strftime('%-I:%M %p')} ({part})" + (f", timezone {tz}" if tz else ""),
    ]
    for k, v in (extra or {}).items():
        if v:
            lines.append(f"- {str(k).replace('_', ' ').capitalize()}: {v}")
    return ("## Your environment — what's true right now. Use it; don't guess or fall back on your "
            "training cutoff.\n" + "\n".join(lines))


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
    files_root: str | None = None,
    user_name: str | None = None,
    mcp_hints_enabled: dict[str, bool] | None = None,
    research_mode: bool = False,
    specialist_mode: bool = False,
    voice_mode: bool = False,
    models_override: dict | None = None,
    environment: dict | None = None,
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
      • tool scope: `working_dir` (the project folder, else the user's configured
        `files_root`, else ~/Documents/LookingGlass) is published to tools via a
        contextvar for the duration of the request.
    Invariant #1 holds — a base system prompt is always present; guidelines are
    purely additive.
    """
    host = ollama_host or config.ollama_host

    # Per-request model routing override (F2 — off-bundle user model config): the app sends
    # a role→model map (the active preset) that layers over the shipped config.toml [models].
    # Rebinding `config` here means every downstream resolver (mode routing, silent-hands)
    # sees the effective table. Absent/empty → identical to the bundled default.
    # See WORKSPACE/model-config-workflow.md.
    if models_override:
        config = replace(config, models={**config.models, **models_override})

    project_cfg = load_project(project_dir)

    # Model resolution (Step 5): explicit picker > mode-aware routing > fallback.
    # classify_mode inspects the last user message; project_model_for_mode consults
    # the project's [models] table first, then the global routing table.
    # When the user picks a specific model in Swift, `model` is set and we skip routing.
    # Research mode always routes to the research model regardless of message content.
    # Deep-research ALWAYS routes to the research model — even when the user has a
    # specific model pinned. Pressing the research button is an explicit "take this
    # deep" intent that overrides the picker (and is the consent to use the large
    # cloud research model). Outside research mode, an explicit pick wins; otherwise
    # the keyword classifier routes.
    if research_mode:
        # The research button = LARGE deep research. Prefer the dedicated `deep_research`
        # lane (fleet: gpt-oss:120b-cloud); fall back to `research` for configs that don't
        # split medium/deep (the stable lock has only `research`).
        mode = "research"
        resolved_model = (
            project_model_for_mode(project_cfg, config.models, "deep_research")
            or project_model_for_mode(project_cfg, config.models, "research")
            or config.default_model
        )
    elif specialist_mode:
        # Per-turn "consult the big model" — routes to the specialist regardless of the
        # picker (the user's tap is the explicit intent + consent). No skill inlining.
        mode = "specialist"
        resolved_model = (
            project_model_for_mode(project_cfg, config.models, "specialist")
            or config.default_model
        )
    else:
        mode = classify_mode(messages) if model is None else "default"
        resolved_model = (
            model
            or project_model_for_mode(project_cfg, config.models, mode)
            or config.default_model
        )

    base_prompt = system_prompt if (system_prompt and system_prompt.strip()) else config.system_prompt
    if user_name and user_name.strip():
        base_prompt = f"The user's name is {user_name.strip()}.\n\n" + base_prompt
    # Situate Alice in her environment (date/time/timezone) so she doesn't guess or fall back on her
    # training cutoff — the root of the wrong-year fabrications. Extensible via _ambient_context(extra):
    # Swift can later add precise location + weather + device state. (2026-07-09; fix_current_date_injection)
    base_prompt = _ambient_context(environment) + "\n\n" + base_prompt

    # Output scope: explicit working_dir → project folder → user's configured
    # files root (independent chats) → default ~/Documents/LookingGlass. Tool
    # outputs are organized into type subfolders under this root (see output_subdir).
    scope = working_dir or project_dir or files_root
    work_path = Path(scope).expanduser() if scope else Path.home() / "Documents" / "LookingGlass"
    try:
        work_path.mkdir(parents=True, exist_ok=True)
    except Exception:
        pass

    # Prompt = base Alice (+ project context, when in a project) (+ guidelines).
    # All additive — Invariant #1 keeps a base prompt always present. The project
    # context's path is the live work_path (== tool scope), never a stored copy.
    parts = [base_prompt]

    # Skills index (progressive disclosure): Alice always sees WHICH skills exist;
    # she pulls the full playbook on demand via use_skill. Mirrors the memory-bank's
    # passive recall. Gated on the tool being enabled so prompt ⇄ tools stay consistent.
    use_skill_on = enabled_tools is None or "use_skill" in enabled_tools
    sk_index = skills_index() if use_skill_on else None
    if sk_index:
        parts.append(
            "## Skills\n"
            "You have step-by-step playbooks for these tasks. When a request matches "
            "one, call `use_skill` with its name to load the full instructions before "
            "starting, then follow them.\n\n" + sk_index
        )

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
    # MCP usage hints: each enabled server that advertised prompts contributes
    # its guidance as a block. Injected after project context so Alice sees
    # project-specific instructions first. Entirely opt-in per server.
    if mcp_hints_enabled:
        for server_name, enabled in mcp_hints_enabled.items():
            if enabled:
                for prompt in registry.mcp_prompts_for(server_name):
                    parts.append(prompt["text"])

    if research_mode:
        # Inline the deep-research skill directly — skip the use_skill round-trip so the
        # model starts turn 1 already knowing the plan and can go straight to web_search.
        skill_path = Path(__file__).parent / "skills" / "deep-research" / "SKILL.md"
        skill_body = skill_path.read_text() if skill_path.exists() else ""
        parts.append(
            "## Active mode: Deep Research\n"
            "The user wants a thorough, multi-source research run — not a quick answer. "
            "Follow the playbook below completely. Use web_search and read_page to gather "
            "sources, synthesize a full report, and save it with file_write. "
            "After saving, write a SHORT in-chat handoff (100–150 words): confirm you saved it, "
            "give 3–4 bullet highlights of what you found, and invite them to review and ask for "
            "corrections or deeper dives. Do NOT reproduce the full report in chat — they can "
            "read it in the panel.\n\n"
            + (f"### Research Playbook\n{skill_body}" if skill_body else "")
        )

    if voice_mode:
        # The reply is going to be *heard*, not read. The client already splits
        # spoken prose from on-screen structure, but it can only split what it's
        # given: prose written after a bulleted list usually refers back to it,
        # so removing the list leaves the spoken half jumping between fragments
        # that no longer connect. Marking the boundary explicitly lets the spoken
        # half stay continuous.
        parts.append(
            "## Active mode: Voice\n"
            "Yogi is talking to you out loud and your reply will be read back to him, "
            "so write it to be HEARD. Speak in continuous prose — full sentences that "
            "flow one into the next, the way you'd actually say them. Contractions are "
            "good. Avoid markdown in the spoken part entirely: no bullets, no bold, no "
            "headings.\n\n"
            "If there is genuine detail worth keeping — a comparison, a list of options, "
            "figures, code — put a `---` rule, then that detail, then another `---` rule, "
            "and carry on speaking after it. Everything between the rules is shown on "
            "screen and never read aloud, so the sentences either side must still make "
            "sense read straight through, with the detail skipped. Don't say 'as you can "
            "see below' or refer to it as if he's reading.\n\n"
            "Most replies need no rules at all — just talk. Keep it to what you'd "
            "comfortably say in one breath-group of conversation rather than an essay."
        )

    guidelines = read_guidelines(project_dir)
    if guidelines:
        parts.append(guidelines)
    active_prompt = "\n\n---\n\n".join(parts)

    wd_token = set_working_dir(work_path)
    pd_token = set_project_dir(Path(project_dir).expanduser() if project_dir else None)
    oh_token = set_ollama_host(host)

    full: list[dict] = [{"role": "system", "content": active_prompt}] + messages

    # Research mode: skill is already inlined in the prompt, so exclude use_skill.
    # Leaving it enabled causes the model to call use_skill, output framing prose,
    # and stop — wasting a turn and never reaching the first web_search.
    if research_mode:
        base = enabled_tools if enabled_tools is not None else registry.names()
        effective_tools: list[str] | None = [n for n in base if n != "use_skill"]
    else:
        effective_tools = enabled_tools
    tool_schemas = registry.ollama_schemas(effective_tools)

    total_in = 0
    total_out = 0
    streamed_content = False   # have we emitted any text in a prior turn?

    try:
        async with httpx.AsyncClient(timeout=300.0) as client:
            # Only attach tools if the resolved model can actually use them — a
            # completion-only model (e.g. ZINI) 400s on a `tools` payload.
            attach_tools = bool(tool_schemas) and await _model_supports_tools(
                client, host, resolved_model
            )

            # Silent-hands butler: a distinct tool-capable `hands` model runs the tool loop and the
            # voice model PLATES from the results (passed NO tools → can't fabricate tool calls).
            # Fires ONLY for a tool-LESS voice (e.g. ZINI) — the `not attach_tools` guard. A
            # tool-CAPABLE voice (gemma, a menu-picked model) calls tools DIRECTLY; routing it through a
            # distinct hands model would needlessly CO-LOAD both models (memory pressure + post-tool lag
            # — the 2026-07-09 regression Yogi caught with gemma4:26b-mlx). Skipped for research/
            # specialist (already tool-capable lanes). NOTE: a tool-capable-but-UNRELIABLE voice (ornith,
            # parked 07-08k) would need an explicit opt-in flag to force plating — deferred unless revisited.
            if bool(tool_schemas) and not attach_tools and not research_mode and not specialist_mode:
                hands_model = (
                    project_model_for_mode(project_cfg, config.models, "hands")
                    or project_model_for_mode(project_cfg, config.models, "coding")
                )
                # Deterministic image routing (A): a clear "make me an image" turn — which the
                # keyword router doesn't catch, so it lands here on the tool-less voice model —
                # executes the image tool DIRECTLY (no small model decides which tool or fills
                # model=), then the voice model plates. Works even with no hands model, and keeps
                # the RAM-heavy hands model off the image-gen path. See plan_hands_model_reliability.
                preset_call = None
                img = detect_image_request(messages)
                if img:
                    img_tool = _find_image_tool(registry, effective_tools)
                    if img_tool:
                        preset_call = {"tool": img_tool,
                                       "args": {"prompt": img["prompt"], "mode": img["mode"]}}

                hands_ok = (
                    bool(hands_model)
                    and hands_model != resolved_model
                    and await _model_supports_tools(client, host, hands_model)
                )
                if preset_call is not None or hands_ok:
                    if preset_call is not None:
                        print(f"[agent:route] image request → direct {preset_call['tool']} "
                              f"(mode={img['mode']}) → {resolved_model} plates")
                    else:
                        print(f"[agent] silent-hands: {hands_model} runs tools → {resolved_model} plates")
                    async for ev in _silent_hands_stream(
                        client, host,
                        hands_model=hands_model or resolved_model,
                        voice_model=resolved_model,
                        active_prompt=active_prompt,
                        messages=messages,
                        tool_schemas=tool_schemas,
                        registry=registry,
                        config=config,
                        preset_call=preset_call,
                    ):
                        yield ev
                    return

            for turn in range(config.max_turns):
                payload = {
                    "model": resolved_model,
                    "messages": full,
                    "stream": True,
                    "think": config.think,
                    # Bounds how long Ollama holds the model after we stop talking.
                    # Refreshed by any client, so a shared model isn't yanked early.
                    "keep_alive": config.keep_alive,
                    # Cap the context window — the models' 256K default allocates a
                    # huge KV cache that bloats RAM and chokes big models on 32GB.
                    "options": {"num_ctx": config.num_ctx},
                }
                if attach_tools:
                    payload["tools"] = tool_schemas

                assistant_content = ""
                tool_calls: list[dict] = []
                turn_emitted = False   # has THIS turn emitted text yet?

                # Small local models intermittently emit a malformed tool-call block
                # (e.g. `<function>…</parameter>`) that Ollama's tool parser rejects
                # with a 5xx *before* any tokens stream — measured ~12% per attempt on
                # qwen3.5:4b. The output is stochastic, so re-issuing the identical
                # request almost always succeeds (~0.2% residual after 2 retries).
                # Nothing has streamed for this turn at the status check, so the retry
                # is safe — no duplicated content. (404/400 are NOT retried.)
                MAX_OLLAMA_RETRIES = 3
                ollama_attempt = 0
                while True:
                    assistant_content = ""
                    tool_calls = []
                    turn_emitted = False
                    retry_turn = False

                    try:
                        async with client.stream("POST", f"{host}/api/chat", json=payload) as response:
                            if response.status_code >= 400:
                                # Surface Ollama's actual reason (model not found, OOM,
                                # bad request…) instead of an opaque status code. Must
                                # read the body inside the stream context.
                                body = await response.aread()
                                detail = body.decode("utf-8", "replace").strip()
                                if response.status_code >= 500 and ollama_attempt < MAX_OLLAMA_RETRIES:
                                    ollama_attempt += 1
                                    print(f"[agent] Ollama {response.status_code}, retry "
                                          f"{ollama_attempt}/{MAX_OLLAMA_RETRIES}: {detail[:120]}")
                                    retry_turn = True
                                elif response.status_code == 429:
                                    # Cloud rate limit (free tier). Don't silently fall
                                    # back to a local model — tell the user the tier is
                                    # unavailable so the quality change is never hidden.
                                    yield {"type": "error", "message":
                                           "The cloud model is rate-limited right now (free tier). "
                                           "Give it a moment and try again, or pick a local model for now."}
                                    return
                                else:
                                    msg = f"Ollama HTTP {response.status_code}"
                                    if detail:
                                        msg += f": {detail[:500]}"
                                    yield {"type": "error", "message": msg}
                                    return
                            else:
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
                                        # Separate a new turn's text from the previous
                                        # turn's so post-tool narration doesn't run
                                        # together (e.g. "…for.Hmm" or "…names:Yes").
                                        if streamed_content and not turn_emitted:
                                            yield {"type": "content_delta", "text": "\n\n"}
                                        turn_emitted = True
                                        streamed_content = True
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

                    if retry_turn:
                        await asyncio.sleep(0.25)
                        continue
                    break

                print(f"[agent] turn {turn}: {len(tool_calls)} tool call(s), {len(assistant_content)} chars text")

                # No tools requested this turn → the model is done talking.
                if not tool_calls:
                    # Research mode catch: if the model wrote the report as prose instead
                    # of calling file_write, auto-save it so the user still gets the file.
                    if research_mode and len(assistant_content) > 1500:
                        slug = re.sub(r"[^\w]+", "-", messages[-1].get("content", "report")[:40]).strip("-")
                        slug = slug or f"report-{int(time.time())}"
                        out_path = work_path / "research" / f"{slug}.md"
                        out_path.parent.mkdir(parents=True, exist_ok=True)
                        out_path.write_text(assistant_content, encoding="utf-8")
                        print(f"[agent] research catch: auto-saved report to {out_path}")
                        # Emit a fake file_write result so Swift detects the report path.
                        tc_id = f"tc_{turn}_auto"
                        yield {"type": "tool_call_start", "id": tc_id, "tool": "file_write",
                               "args": {"path": str(out_path)}}
                        yield {"type": "tool_call_result", "id": tc_id, "tool": "file_write",
                               "success": True,
                               "result": f"Wrote {out_path} ({len(assistant_content)} chars)",
                               "latency_ms": 0}
                    yield {
                        "type": "message_end",
                        "model": resolved_model,
                        "usage": {"input_tokens": total_in, "output_tokens": total_out},
                    }
                    return

                # Record the assistant's turn (content + the calls it wants to make).
                full.append({
                    "role": "assistant",
                    "content": assistant_content,
                    "tool_calls": tool_calls,
                })

                # Internal tools (think, use_skill) sometimes cause the model to output
                # framing prose on the next turn and stop instead of doing actual work.
                tc_names = {tc.get("function", {}).get("name") for tc in tool_calls}
                _internal = {"think", "use_skill"}
                if tc_names and tc_names.issubset(_internal):
                    if "use_skill" in tc_names:
                        # After loading a skill, model must start the first step now.
                        full.append({"role": "user",
                                     "content": "Skill loaded. Start executing step 1 now — call the first tool immediately. No framing text."})
                    elif not assistant_content:
                        # After think with no text, nudge to produce the actual reply.
                        full.append({"role": "user", "content": "Now write your answer."})

                # Execute each tool, streaming start/result, and feed results back.
                for i, tc in enumerate(tool_calls):
                    fn = tc.get("function", {})
                    name = fn.get("name", "")
                    raw_args = fn.get("arguments", {})
                    args = _coerce_args(raw_args)
                    tc_id = f"tc_{turn}_{i}"

                    tool = registry.get(name)
                    # Route file-producing tools (e.g. OllamaMCP's local_image) into the
                    # type-organized output folder and drop a placeholder model= — see
                    # _sanitize_tool_args. Authoritative: the model doesn't get to pick
                    # the image save location or pass model="default".
                    args = _sanitize_tool_args(tool, args)

                    yield {"type": "tool_call_start", "id": tc_id, "tool": name, "args": args}

                    start = time.monotonic()
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

                    # Truncate before adding to history — full page reads (60KB) will
                    # overflow the 16K token context window after just 2-3 tool calls.
                    # The SSE stream already sent the full result to the client; the
                    # model only needs enough to reason from, not to re-read the source.
                    raw_result = result.get("result", "")
                    # Mark failures explicitly. The success flag is true on the SSE event
                    # (Swift sees it) but is otherwise lost here — the model would receive
                    # the error string as ordinary tool output and, per BenchLLAMA D4b,
                    # fabricate a plausible value instead of reporting the failure. The
                    # marker gives it an unambiguous signal not to.
                    if not result.get("success", False):
                        raw_result = (
                            "[TOOL ERROR — this call FAILED. Do not fabricate, guess, or "
                            "infer its output. Tell the user the tool failed and stop or "
                            f"retry.] {raw_result}"
                        )
                    history_result = (
                        raw_result[:6_000] + "\n…[truncated for context window]"
                        if len(raw_result) > 6_000 else raw_result
                    )
                    full.append({
                        "role": "tool",
                        "content": history_result,
                        "tool_name": name,
                    })

            # Hit the turn ceiling without the model settling.
            yield {
                "type": "message_end",
                "model": resolved_model,
                "usage": {"input_tokens": total_in, "output_tokens": total_out},
            }
    finally:
        # Best-effort context cleanup. If the SSE stream is cancelled/closed in a
        # different asyncio context than it started (client disconnect, early break),
        # resetting the contextvar token raises ValueError — harmless cleanup noise,
        # so don't let it propagate out of the generator's teardown.
        for _reset, _tok in ((reset_working_dir, wd_token), (reset_project_dir, pd_token), (reset_ollama_host, oh_token)):
            try:
                _reset(_tok)
            except (ValueError, LookupError):
                pass


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
