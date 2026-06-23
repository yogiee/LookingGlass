import importlib
import pkgutil

from .base import Tool, err, ok


class ToolRegistry:
    """Discovers and holds all available tools.

    Auto-discovery: every module under tools/builtin/ that exposes a
    module-level `TOOLS: list[Tool]` is loaded automatically. Drop a new
    file in builtin/, restart the sidecar, and the tool is available —
    no other code changes (invariant #4).

    MCP servers are registered via discover_mcp() during startup. Their tools
    appear alongside builtins with category="mcp"; the agent loop treats them
    identically. Call shutdown() in the lifespan teardown to stop all servers.
    """

    def __init__(self) -> None:
        self._tools: dict[str, Tool] = {}
        self._mcp_connections: list = []   # McpConnection objects
        self._mcp_status: dict[str, str] = {}   # name → "connected" | "failed"
        self._mcp_prompts: dict[str, list[dict]] = {}  # name → [{name, description, text}]

    def register(self, tool: Tool) -> None:
        self._tools[tool.name] = tool

    def discover(self) -> None:
        from . import builtin as builtin_pkg

        for mod_info in pkgutil.iter_modules(builtin_pkg.__path__):
            module = importlib.import_module(f"tools.builtin.{mod_info.name}")
            for tool in getattr(module, "TOOLS", []):
                self.register(tool)

    def get(self, name: str) -> Tool | None:
        return self._tools.get(name)

    def all(self) -> list[Tool]:
        return list(self._tools.values())

    def names(self) -> list[str]:
        return list(self._tools.keys())

    def ollama_schemas(self, enabled: list[str] | None) -> list[dict]:
        """Function schemas for the tools that are enabled this request.

        enabled=None means "all"; an empty list means "none".
        """
        if enabled is None:
            selected = self._tools.values()
        else:
            selected = (self._tools[n] for n in enabled if n in self._tools)
        return [t.to_ollama() for t in selected]

    def describe_all(self) -> list[dict]:
        return [t.describe() for t in self._tools.values()]

    async def discover_mcp(self, servers_config: list[dict]) -> None:
        """Connect to each configured MCP server and register its tools.

        Called once during sidecar startup (inside the FastAPI lifespan).
        Failed servers are logged and skipped — they don't prevent startup.
        """
        from mcp_client import McpConnection

        for cfg in servers_config:
            name = cfg.get("name") or "unnamed"
            command = cfg.get("command", "")
            args = cfg.get("args") or []
            env = cfg.get("env") or {}
            if not command:
                print(f"[mcp] {name}: skipped — no command configured")
                continue

            conn = McpConnection(name, command, args, env)
            try:
                await conn.start()
                for mcp_tool in conn.tools:
                    self.register(_wrap_mcp_tool(conn, mcp_tool, server_name=name))
                # Cache prompts without required arguments — these are system-level
                # usage hints that any host can inject into the active system prompt.
                cached_prompts = []
                for p in conn.prompts:
                    has_required = any(
                        getattr(a, "required", False)
                        for a in (getattr(p, "arguments", None) or [])
                    )
                    if has_required:
                        continue
                    try:
                        result = await conn.get_prompt(p.name, {})
                        text = "\n\n".join(
                            msg.content.text
                            for msg in result.messages
                            if hasattr(msg.content, "text") and msg.content.text
                        )
                        if text:
                            cached_prompts.append({
                                "name": p.name,
                                "description": getattr(p, "description", "") or "",
                                "text": text,
                            })
                    except Exception:
                        pass
                self._mcp_prompts[name] = cached_prompts
                self._mcp_connections.append(conn)
                self._mcp_status[name] = "connected"
                prompt_info = f", {len(cached_prompts)} prompts" if cached_prompts else ""
                print(f"[mcp] {name}: connected ({len(conn.tools)} tools{prompt_info})")
            except Exception as exc:
                self._mcp_status[name] = "failed"
                print(f"[mcp] {name}: failed to start — {exc}")

    def mcp_status(self) -> dict[str, str]:
        return dict(self._mcp_status)

    def mcp_prompts_for(self, server_name: str) -> list[dict]:
        """Return cached prompts for a server — [{name, description, text}]."""
        return self._mcp_prompts.get(server_name, [])

    def mcp_prompts_index(self) -> dict[str, list[dict]]:
        """All cached prompts keyed by server name, name/description only (no text)."""
        return {
            name: [{"name": p["name"], "description": p["description"]} for p in prompts]
            for name, prompts in self._mcp_prompts.items()
            if prompts
        }

    async def shutdown(self) -> None:
        """Stop all MCP server connections. Called on sidecar shutdown."""
        for conn in self._mcp_connections:
            try:
                await conn.stop()
            except Exception:
                pass
        self._mcp_connections.clear()


# MCP tools that return errors as plain text (no isError flag) overwhelmingly use a
# leading "Error" by convention. Match only that narrow prefix so a legitimate result
# that merely mentions "error" mid-text is never misflagged.
_TOOL_ERROR_PREFIXES = ("error:", "error from ", "error generating", "error loading")


def _looks_like_tool_error(text: str) -> bool:
    return text.lstrip().lower().startswith(_TOOL_ERROR_PREFIXES)


def _wrap_mcp_tool(conn, mcp_tool, server_name: str = "") -> Tool:
    """Wrap one MCP tool as a sidecar Tool with a proxying async handler.

    Tools are registered as `{server_name}__{tool_name}` to avoid collisions
    between MCP servers and builtins (e.g. both have `save_memory`).
    """
    raw_name = mcp_tool.name
    prefixed_name = f"{server_name}__{raw_name}" if server_name else raw_name

    async def handler(args: dict) -> dict:
        try:
            result = await conn.call_tool(raw_name, args)
            text = "\n".join(
                c.text for c in result.content if hasattr(c, "text") and c.text
            )
            if not text:
                return err("MCP tool returned no text content.")
            # Surface real failures as failures. Two cases the agent loop must not
            # mistake for success (otherwise the model relays the raw error as if it
            # were a result, or fabricates around it — see agent.py's [TOOL ERROR] mark):
            #   1. MCP-native: the server set isError on the CallToolResult.
            #   2. String-convention: many MCP tools (e.g. OllamaMCP's local_image)
            #      return an error as ordinary text — "Error: …" / "Error from …".
            #      Detect that narrow, conventional prefix so it's marked, not parroted.
            if getattr(result, "isError", False) or _looks_like_tool_error(text):
                return err(text)
            return ok(text)
        except Exception as exc:
            return err(f"{type(exc).__name__}: {exc}")

    return Tool(
        name=prefixed_name,
        description=mcp_tool.description or "",
        parameters=mcp_tool.inputSchema or {"type": "object", "properties": {}},
        handler=handler,
        category="mcp",
    )
