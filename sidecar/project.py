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
