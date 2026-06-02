"""Project-folder interpretation (Phase 3, Step 3).

Swift creates a project folder and sends its absolute path as `project_dir` on
`/chat`; the sidecar reads it here. The folder is the whole contract — the
sidecar never learns the conversation DB. See
WORKSPACE/phase3-projects-and-persistence.md §5–9.
"""
import tomllib
from pathlib import Path


def load_project(project_dir: str | None) -> dict | None:
    """Parse `<project_dir>/project.toml`. None if absent or unreadable."""
    if not project_dir:
        return None
    toml_path = Path(project_dir).expanduser() / "project.toml"
    if not toml_path.is_file():
        return None
    try:
        with open(toml_path, "rb") as f:
            return tomllib.load(f)
    except Exception:
        return None


def project_default_model(project_cfg: dict | None) -> str | None:
    """The project's `[models].default`, if declared."""
    if not project_cfg:
        return None
    return project_cfg.get("models", {}).get("default") or None


def project_context(project_cfg: dict | None, working_dir: str) -> str | None:
    """A short, runtime-composed 'project context' block for the system prompt.

    Makes Alice aware of *where* she is and *what* the project is. Identity/metadata
    (name, description) come from `project.toml`; the **path comes from the live
    working dir** — the same value tools are scoped to — so it can never drift from
    a stored copy. Additive to the base Alice prompt (Invariant #1).
    """
    proj = (project_cfg or {}).get("project", {})
    name = (proj.get("name") or "").strip()
    desc = (proj.get("description") or "").strip()

    lines = ["## Project context"]
    lines.append(f'You\'re working in the project "{name}".' if name
                 else "You're working inside a project.")
    if desc:
        lines.append(f"About: {desc}")
    lines.append(f"Working directory: {working_dir}")
    lines.append(
        "Files and shell are scoped to this folder — use relative paths; everything "
        "you create lands here unless told otherwise."
    )
    return "\n".join(lines)


def read_guidelines(project_dir: str | None) -> str | None:
    """`<project_dir>/guidelines.md` contents (trimmed), or None."""
    if not project_dir:
        return None
    path = Path(project_dir).expanduser() / "guidelines.md"
    if not path.is_file():
        return None
    try:
        text = path.read_text(encoding="utf-8").strip()
        return text or None
    except Exception:
        return None
