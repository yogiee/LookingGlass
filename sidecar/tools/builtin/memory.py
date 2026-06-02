"""save_memory — durable per-project notes (Phase 3, Step 4).

Writes a frontmatter markdown file into the active project's `memory-bank/` and
keeps a `MEMORY.md` index, mirroring this repo's own memory convention. Only
meaningful inside a project: the memory-bank belongs to the project folder, which
the request carries via the `project_dir` contextvar.

`save_memory_entry` is the core, used by BOTH the tool (Alice-driven, model decides
to call it) and a future `/memory/save` HTTP endpoint (the deterministic, no-model
per-message "Save to memory" button) — same write path, two triggers.
"""
import re
from datetime import date
from pathlib import Path

from ..base import Tool, ok, err
from ..context import project_dir

VALID_TYPES = {"project", "reference", "feedback", "user"}


def _slugify(title: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", title.strip().lower()).strip("-")
    return (s or "memory")[:60]


def _yaml_inline(s: str) -> str:
    """Quote a one-line scalar only when it contains YAML-significant characters."""
    s = s.replace("\n", " ").strip()
    if s and not re.search(r'[:#"\[\]{}|>&*!%@`]', s) and not s[0] in "'\"- ":
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _memory_bank() -> Path | None:
    """The active project's memory-bank dir, or None outside a project."""
    proj = project_dir()
    return (proj / "memory-bank") if proj is not None else None


def _upsert_index(bank: Path, slug: str, title: str, desc: str) -> None:
    """Ensure one index line per memory: replace the slug's line, else append."""
    index = bank / "MEMORY.md"
    line = f"- [{title}]({slug}.md) — {desc}"
    lines = index.read_text(encoding="utf-8").splitlines() if index.is_file() else ["# Memory Index", ""]
    token = f"]({slug}.md)"
    for i, ln in enumerate(lines):
        if token in ln:
            lines[i] = line
            break
    else:
        lines.append(line)
    index.write_text("\n".join(lines) + "\n", encoding="utf-8")


def save_memory_entry(title: str, content: str, description: str | None = None,
                      mem_type: str = "project") -> dict:
    """Write/overwrite a memory file + update the index. Returns ok()/err()."""
    bank = _memory_bank()
    if bank is None:
        return err("save_memory only works inside a project — open or create a project first.")

    title = (title or "").strip()
    content = (content or "").strip()
    if not title:
        return err("Missing required argument: title")
    if not content:
        return err("Missing required argument: content")

    mem_type = mem_type if mem_type in VALID_TYPES else "project"
    desc = (description or "").strip() or content.splitlines()[0][:120]
    slug = _slugify(title)

    try:
        bank.mkdir(parents=True, exist_ok=True)
        body = (
            "---\n"
            f"name: {slug}\n"
            f"description: {_yaml_inline(desc)}\n"
            "metadata:\n"
            f"  type: {mem_type}\n"
            f"created: {date.today().isoformat()}\n"
            "---\n\n"
            f"{content}\n"
        )
        (bank / f"{slug}.md").write_text(body, encoding="utf-8")
        _upsert_index(bank, slug, title, desc)
    except Exception as e:
        return err(f"{type(e).__name__}: {e}")

    return ok(f"Saved memory '{title}' → memory-bank/{slug}.md")


async def _save_memory(args: dict) -> dict:
    return save_memory_entry(
        title=args.get("title"),
        content=args.get("content"),
        description=args.get("description"),
        mem_type=args.get("type", "project"),
    )


TOOLS = [
    Tool(
        name="save_memory",
        description=(
            "Save a durable note into the current project's memory-bank so it can be "
            "recalled in future conversations. Only works inside a project. Use it when "
            "the user asks you to remember something, or when a decision, fact, or "
            "preference is clearly worth keeping. Provide a short title and the content."
        ),
        parameters={
            "type": "object",
            "properties": {
                "title": {"type": "string", "description": "Short human title for the memory (also its filename and index entry)"},
                "content": {"type": "string", "description": "The note to remember, in markdown. Be specific and self-contained."},
                "description": {"type": "string", "description": "Optional one-line summary for the index (defaults to the first line of content)"},
                "type": {"type": "string", "enum": ["project", "reference", "feedback", "user"], "description": "Memory kind; defaults to 'project'"},
            },
            "required": ["title", "content"],
        },
        handler=_save_memory,
        category="memory",
    ),
]
