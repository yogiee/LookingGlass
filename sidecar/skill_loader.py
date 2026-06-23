"""Skill discovery + loading (progressive disclosure).

A *skill* is a folder under sidecar/skills/<name>/ holding a SKILL.md: frontmatter
(name, description, when_to_use, allowed_tools) + a markdown body of instructions.
Only the frontmatter is injected into the system prompt at request time (the
"index"); the full body is pulled on demand by the use_skill tool — the same
passive-recall pattern as the project memory-bank (see project.read_memory_index +
the recall_memory tool).

Skills are re-read from disk per request, so dropping or editing a SKILL.md takes
effect with no sidecar restart (cf. the tools' auto-discovery, invariant #4).
"""
from dataclasses import dataclass
from pathlib import Path

# Shipped skills ride in the bundle (versioned with the app, always fresh on update).
SHIPPED_SKILLS_DIR = Path(__file__).parent / "skills"
# User-added/imported skills live OUTSIDE the bundle so an app update — which replaces
# Contents/Resources/sidecar wholesale — never wipes them (same rule as the MCP config
# and history.db). On a name collision the user copy wins, so a user can override a
# built-in by reusing its name.
USER_SKILLS_DIR = (
    Path.home() / "Library" / "Application Support" / "LookingGlass" / "skills"
)


def _skill_dirs() -> list[Path]:
    """Skill folders from both roots — shipped first, then user, so a same-named
    user skill overrides the built-in (see all_skills' dict merge)."""
    dirs: list[Path] = []
    for root in (SHIPPED_SKILLS_DIR, USER_SKILLS_DIR):
        if root.is_dir():
            dirs.extend(d for d in sorted(root.iterdir()) if d.is_dir())
    return dirs


def is_builtin(name: str) -> bool:
    """Whether a skill ships in the bundle (and so can't be deleted by the user)."""
    return (SHIPPED_SKILLS_DIR / (name or "")).is_dir()


@dataclass
class Skill:
    name: str               # canonical id; defaults to the folder name
    description: str        # the one required field
    when_to_use: str
    allowed_tools: list[str]
    body: str               # the playbook (everything after the frontmatter)
    path: Path


def _parse_frontmatter(block: str) -> dict:
    """Minimal YAML subset: `key: value` scalars + inline `[a, b]` lists.
    Deliberately tiny — avoids a PyYAML dependency and matches the repo's
    hand-rolled frontmatter style (tools/builtin/memory.py)."""
    fm: dict = {}
    for line in block.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, _, val = line.partition(":")
        key, val = key.strip(), val.strip()
        if val.startswith("[") and val.endswith("]"):
            items = [v.strip().strip("'\"") for v in val[1:-1].split(",")]
            fm[key] = [v for v in items if v]
        else:
            fm[key] = val.strip("'\"")
    return fm


def _split_frontmatter(text: str) -> tuple[dict, str]:
    """(frontmatter_dict, body). Tolerates a missing/short frontmatter block."""
    if not text.startswith("---"):
        return {}, text.strip()
    parts = text.split("---", 2)          # ["", "<frontmatter>", "<body>"]
    if len(parts) < 3:
        return {}, text.strip()
    return _parse_frontmatter(parts[1]), parts[2].strip()


def _load_one(skill_dir: Path) -> "Skill | None":
    md = skill_dir / "SKILL.md"
    if not md.is_file():
        return None
    try:
        fm, body = _split_frontmatter(md.read_text(encoding="utf-8"))
    except Exception:
        return None
    desc = (fm.get("description") or "").strip()
    if not desc:                          # description is the only hard requirement
        return None
    allowed = fm.get("allowed_tools") or []
    if isinstance(allowed, str):
        allowed = [t.strip() for t in allowed.split(",") if t.strip()]
    return Skill(
        name=(fm.get("name") or skill_dir.name).strip(),
        description=desc,
        when_to_use=(fm.get("when_to_use") or "").strip(),
        allowed_tools=allowed,
        body=body,
        path=md,
    )


def all_skills() -> list[Skill]:
    """Every valid skill across the shipped (bundle) and user (Application Support)
    roots, sorted by name. Filesystem scan per call — cheap and keeps skills
    live-editable. A user skill overrides a shipped one of the same name."""
    by_name: dict[str, Skill] = {}
    for d in _skill_dirs():               # shipped first, then user (user wins)
        s = _load_one(d)
        if s is not None:
            by_name[s.name] = s
    return sorted(by_name.values(), key=lambda s: s.name)


def get_skill(name: str) -> "Skill | None":
    name = (name or "").strip()
    return next((s for s in all_skills() if s.name == name), None)


def skills_index() -> "str | None":
    """The injected 'index': one line per skill. None when there are no skills, so
    the prompt block is omitted entirely."""
    skills = all_skills()
    if not skills:
        return None
    lines = []
    for s in skills:
        when = f" — use when: {s.when_to_use}" if s.when_to_use else ""
        lines.append(f"- **{s.name}** — {s.description}{when}")
    return "\n".join(lines)
