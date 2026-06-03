"""Per-request tool context (Phase 3, Step 3).

The agent loop sets a `working_dir` for the duration of a `/chat` request; tools
read it to resolve relative paths and pick a default `cwd`. Carried via a
`contextvar` so the existing `handler(args)` signature stays unchanged
(invariant #4) and concurrent requests stay isolated (each asyncio task gets its
own context copy).

Outside a chat request the var is None and tools fall back to the user's home —
i.e. the pre–Step 3 behaviour.
"""
import contextvars
from pathlib import Path

_working_dir: contextvars.ContextVar[Path | None] = contextvars.ContextVar(
    "working_dir", default=None
)

_ollama_host: contextvars.ContextVar[str] = contextvars.ContextVar(
    "ollama_host", default="http://localhost:11434"
)

# The project folder for this request, or None for an independent chat. Distinct
# from working_dir: the latter is the tool *output scope* (and can be overridden);
# project_dir identifies project membership and anchors the memory-bank, which
# always belongs to the project itself.
_project_dir: contextvars.ContextVar[Path | None] = contextvars.ContextVar(
    "project_dir", default=None
)


def set_working_dir(path: Path):
    """Set the request's working dir; returns a token to reset() with."""
    return _working_dir.set(path)


def reset_working_dir(token) -> None:
    _working_dir.reset(token)


def working_dir() -> Path | None:
    """The active request's working dir, or None outside a chat request."""
    return _working_dir.get()


def set_project_dir(path: Path | None):
    """Set the request's project dir (None for independent chats)."""
    return _project_dir.set(path)


def reset_project_dir(token) -> None:
    _project_dir.reset(token)


def project_dir() -> Path | None:
    """The active request's project folder, or None outside a project chat."""
    return _project_dir.get()


def set_ollama_host(host: str):
    """Set the Ollama host for this request; returns a token to reset() with."""
    return _ollama_host.set(host)


def reset_ollama_host(token) -> None:
    _ollama_host.reset(token)


def ollama_host() -> str:
    """The active request's Ollama host URL."""
    return _ollama_host.get()
