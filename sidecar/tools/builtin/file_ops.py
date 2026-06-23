from pathlib import Path

from ..base import Tool, ok, err
from ..context import working_dir, output_subdir

MAX_READ_BYTES = 256_000


def _resolve(path: str) -> Path:
    """Absolute paths and ~ are honored as-is; relative paths resolve against the
    request's working dir (the project folder, or the user's files root), falling
    back to home outside a chat request."""
    p = Path(path).expanduser()
    if p.is_absolute():
        return p.resolve()
    base = working_dir() or Path.home()
    return (base / p).resolve()


def _resolve_write(path: str) -> Path:
    """Like _resolve, but a bare filename (no directory component) lands in the
    `documents/` type folder so written text/markdown stays organized. Paths that
    include a directory, or absolute/~ paths, are honored exactly as given."""
    p = Path(path).expanduser()
    if not p.is_absolute() and p.parent == Path("."):
        return (output_subdir("documents") / p.name).resolve()
    return _resolve(path)


def _resolve_read(path: str) -> Path:
    """Resolve for reading: try the working dir first, then fall back to the
    `documents/` folder so a file written by its bare name is still found."""
    p = _resolve(path)
    if not p.exists() and not Path(path).expanduser().is_absolute():
        alt = (output_subdir("documents") / Path(path).name).resolve()
        if alt.exists():
            return alt
    return p


async def _file_read(args: dict) -> dict:
    path = args.get("path")
    if not path:
        return err("Missing required argument: path")
    p = _resolve_read(path)
    if not p.exists():
        return err(f"File not found: {p}")
    if not p.is_file():
        return err(f"Not a file: {p}")
    try:
        data = p.read_bytes()
        if len(data) > MAX_READ_BYTES:
            text = data[:MAX_READ_BYTES].decode("utf-8", errors="replace")
            return ok(f"{text}\n\n[truncated at {MAX_READ_BYTES} bytes — file is {len(data)} bytes]")
        return ok(data.decode("utf-8", errors="replace"))
    except Exception as e:
        return err(f"{type(e).__name__}: {e}")


async def _file_write(args: dict) -> dict:
    path = args.get("path")
    content = args.get("content", "")
    append = bool(args.get("append", False))
    if not path:
        return err("Missing required argument: path")
    p = _resolve_write(path)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        mode = "a" if append else "w"
        with open(p, mode, encoding="utf-8") as f:
            f.write(content)
        verb = "Appended to" if append else "Wrote"
        return ok(f"{verb} {p} ({len(content)} chars)")
    except Exception as e:
        return err(f"{type(e).__name__}: {e}")


async def _apply_patch(args: dict) -> dict:
    """Surgical edit: replace an exact substring with a new one.

    This is the most reliable edit primitive for LLMs — far less error-prone
    than emitting a full unified diff. old_string must match exactly and be
    unique unless replace_all is set.
    """
    path = args.get("path")
    old = args.get("old_string")
    new = args.get("new_string", "")
    replace_all = bool(args.get("replace_all", False))

    if not path or old is None:
        return err("Missing required arguments: path and old_string")

    p = _resolve_read(path)
    if not p.exists():
        return err(f"File not found: {p}")
    try:
        text = p.read_text(encoding="utf-8")
    except Exception as e:
        return err(f"{type(e).__name__}: {e}")

    count = text.count(old)
    if count == 0:
        return err("old_string not found in file")
    if count > 1 and not replace_all:
        return err(f"old_string appears {count} times — pass replace_all=true or add more context to make it unique")

    updated = text.replace(old, new) if replace_all else text.replace(old, new, 1)
    try:
        p.write_text(updated, encoding="utf-8")
    except Exception as e:
        return err(f"{type(e).__name__}: {e}")
    return ok(f"Patched {p} ({count if replace_all else 1} replacement{'s' if (replace_all and count != 1) else ''})")


TOOLS = [
    Tool(
        name="file_read",
        description="Read the contents of a text file from disk. Returns the file content as a string.",
        parameters={
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "File path — relative paths resolve inside the current project folder; absolute and ~ paths are honored as-is"},
            },
            "required": ["path"],
        },
        handler=_file_read,
        category="filesystem",
    ),
    Tool(
        name="file_write",
        description="Write text content to a file, creating parent directories as needed. Overwrites by default; set append=true to append.",
        parameters={
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Path to write to. A bare filename (e.g. 'notes.md') lands in the documents folder automatically; include a subfolder or pass an absolute/~ path to control the location exactly."},
                "content": {"type": "string", "description": "Text content to write"},
                "append": {"type": "boolean", "description": "Append instead of overwrite"},
            },
            "required": ["path", "content"],
        },
        handler=_file_write,
        category="filesystem",
        dangerous=True,
    ),
    Tool(
        name="apply_patch",
        description="Make a surgical edit to a file by replacing an exact substring. old_string must match exactly; it must be unique unless replace_all is true.",
        parameters={
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Path to the file to edit"},
                "old_string": {"type": "string", "description": "Exact text to find and replace"},
                "new_string": {"type": "string", "description": "Replacement text"},
                "replace_all": {"type": "boolean", "description": "Replace every occurrence"},
            },
            "required": ["path", "old_string", "new_string"],
        },
        handler=_apply_patch,
        category="filesystem",
        dangerous=True,
    ),
]
