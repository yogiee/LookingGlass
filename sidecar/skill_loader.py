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

SKILLS_DIR = Path(__file__).parent / "skills"


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
    """Every valid skill under skills/, sorted by folder name. Filesystem scan per
    call — cheap (a handful of small files) and keeps skills live-editable."""
    if not SKILLS_DIR.is_dir():
        return []
    found = (_load_one(d) for d in sorted(SKILLS_DIR.iterdir()) if d.is_dir())
    return [s for s in found if s is not None]


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
