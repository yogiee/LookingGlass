from dataclasses import dataclass, field
from typing import Awaitable, Callable

# A tool handler takes a dict of arguments and returns a result dict:
#   {"success": bool, "result": str}
# Keeping args as a single dict (rather than **kwargs) avoids surprises when
# the model emits unexpected argument keys.
ToolHandler = Callable[[dict], Awaitable[dict]]


@dataclass
class Tool:
    name: str
    description: str
    parameters: dict          # JSON Schema for the function's arguments
    handler: ToolHandler
    category: str = "general"
    dangerous: bool = False   # hint for the UI (shell_exec, file_write, etc.)

    def to_ollama(self) -> dict:
        """Ollama / OpenAI-compatible function schema."""
        return {
            "type": "function",
            "function": {
                "name": self.name,
                "description": self.description,
                "parameters": self.parameters,
            },
        }

    def describe(self) -> dict:
        """Lightweight description for the /tools endpoint."""
        return {
            "name": self.name,
            "description": self.description,
            "category": self.category,
            "dangerous": self.dangerous,
        }


def ok(result: str) -> dict:
    return {"success": True, "result": result}


def err(message: str) -> dict:
    return {"success": False, "result": message}
