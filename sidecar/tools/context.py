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


def set_working_dir(path: Path):
    """Set the request's working dir; returns a token to reset() with."""
    return _working_dir.set(path)


def reset_working_dir(token) -> None:
    _working_dir.reset(token)


def working_dir() -> Path | None:
    """The active request's working dir, or None outside a chat request."""
    return _working_dir.get()
