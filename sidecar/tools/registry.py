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
        self._mcp_status: dict[str, str] = {}  # name → "connected" | "failed"

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
                    self.register(_wrap_mcp_tool(conn, mcp_tool))
                self._mcp_connections.append(conn)
                self._mcp_status[name] = "connected"
                print(f"[mcp] {name}: connected ({len(conn.tools)} tools)")
            except Exception as exc:
                self._mcp_status[name] = "failed"
                print(f"[mcp] {name}: failed to start — {exc}")

    def mcp_status(self) -> dict[str, str]:
        return dict(self._mcp_status)

    async def shutdown(self) -> None:
        """Stop all MCP server connections. Called on sidecar shutdown."""
        for conn in self._mcp_connections:
            try:
                await conn.stop()
            except Exception:
                pass
        self._mcp_connections.clear()


def _wrap_mcp_tool(conn, mcp_tool) -> Tool:
    """Wrap one MCP tool as a sidecar Tool with a proxying async handler."""
    tool_name = mcp_tool.name

    async def handler(args: dict) -> dict:
        try:
            result = await conn.call_tool(tool_name, args)
            text = "\n".join(
                c.text for c in result.content if hasattr(c, "text") and c.text
            )
            return ok(text) if text else err("MCP tool returned no text content.")
        except Exception as exc:
            return err(f"{type(exc).__name__}: {exc}")

    return Tool(
        name=tool_name,
        description=mcp_tool.description or "",
        parameters=mcp_tool.inputSchema or {"type": "object", "properties": {}},
        handler=handler,
        category="mcp",
    )
