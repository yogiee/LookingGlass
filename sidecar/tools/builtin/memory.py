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


def _tokenize(s: str) -> list[str]:
    """Words ≥3 chars, lowercased — for lenient keyword matching."""
    return [t for t in re.split(r"[^a-z0-9]+", s.lower()) if len(t) >= 3]


def _memory_listing(bank: Path) -> str:
    """The MEMORY.md index if present, else a generated title list."""
    index = bank / "MEMORY.md"
    if index.is_file():
        text = index.read_text(encoding="utf-8").strip()
        if text:
            return text
    files = sorted(f for f in bank.glob("*.md") if f.name != "MEMORY.md")
    return "Saved memories:\n" + "\n".join(f"- {f.stem}" for f in files)


def recall_memory_entry(query: str | None = None) -> dict:
    """List saved memories (no query) or return matching ones in full (query).

    Matching is **token-based, not literal-substring**: the query is split into
    words and a memory scores by how many of them appear in its filename + body
    (with a bonus for a full-phrase hit), results ranked by score. A naive
    `phrase in text` check almost never matches a natural question, which is what
    made recall flail. If nothing scores, we **return the index instead of a dead
    end**, so Alice can always answer from the list of titles."""
    bank = _memory_bank()
    if bank is None:
        return err("recall_memory only works inside a project — open or create a project first.")
    if not bank.is_dir():
        return ok("No memories have been saved in this project yet.")

    mem_files = sorted(f for f in bank.glob("*.md") if f.name != "MEMORY.md")
    if not mem_files:
        return ok("No memories have been saved in this project yet.")

    q = (query or "").strip()
    if not q:
        return ok(_memory_listing(bank))

    tokens = _tokenize(q)
    scored: list[tuple[int, str, str]] = []
    for f in mem_files:
        try:
            text = f.read_text(encoding="utf-8")
        except Exception:
            continue
        hay = (f.stem + " " + text).lower()
        score = sum(1 for t in tokens if t in hay)
        if q.lower() in text.lower():        # full-phrase bonus
            score += len(tokens) or 1
        if score > 0:
            scored.append((score, f.name, text.strip()))

    if not scored:
        # Never dead-end: show what's saved so Alice can still answer from the index.
        return ok(f"No memory directly matched \"{query}\". Everything saved in this "
                  f"project:\n\n{_memory_listing(bank)}")

    scored.sort(key=lambda x: -x[0])
    chunks = [f"### {name}\n{text}" for _, name, text in scored[:5]]
    more = "" if len(scored) <= 5 else f"\n\n(+{len(scored) - 5} more — refine the query.)"
    return ok("\n\n".join(chunks) + more)


async def _save_memory(args: dict) -> dict:
    return save_memory_entry(
        title=args.get("title"),
        content=args.get("content"),
        description=args.get("description"),
        mem_type=args.get("type", "project"),
    )


async def _recall_memory(args: dict) -> dict:
    return recall_memory_entry(query=args.get("query"))


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
    Tool(
        name="recall_memory",
        description=(
            "Recall notes you previously saved in this project's memory-bank. Call with a "
            "topic/keyword to read matching memories in full; call with no query to list "
            "everything saved. Only works inside a project. Use it when the user refers to "
            "something from a past conversation, or when earlier context would help."
        ),
        parameters={
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Topic or keyword to search saved memories; omit to list all"},
            },
        },
        handler=_recall_memory,
        category="memory",
    ),
]
