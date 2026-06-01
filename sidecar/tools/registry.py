import importlib
import pkgutil

from .base import Tool


class ToolRegistry:
    """Discovers and holds all available tools.

    Auto-discovery: every module under tools/builtin/ that exposes a
    module-level `TOOLS: list[Tool]` is loaded automatically. Drop a new
    file in builtin/, restart the sidecar, and the tool is available —
    no other code changes (invariant #4).
    """

    def __init__(self) -> None:
        self._tools: dict[str, Tool] = {}

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
