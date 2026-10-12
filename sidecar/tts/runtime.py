"""The voice runtime: mlx-audio and the libraries only it needs, installed on demand.

About 540 MB installed (≈120 MB of wheels) that only the QUALITY / QUALITY+ voices use, so it lives in Application
Support instead of the app bundle (decision_lean_bundle_ondemand_aux): the app stays ~100 MB of sidecar and an
update doesn't re-ship it. It installs with the first QUALITY download, or from Settings → Voice. The folder is
keyed by Python version, because several of the wheels hold compiled code for one interpreter ABI.

Install = resolve → download → install:

1. **Resolve.** `pip install --dry-run --report` against requirements-voice.txt picks the exact wheels for THIS
   interpreter and reports their URLs and sha256, without downloading them (PyPI serves wheel metadata separately).
2. **Download.** Our own resumable, cancellable downloader (download.py), with progress, then a sha256 check of
   every wheel.
3. **Install.** `pip install --no-index --no-deps --target <staging>` from the local wheels, a marker recording
   the lock it was built from, and an atomic rename into place.

The lock holds only packages the base sidecar doesn't already have, and the folder is APPENDED to sys.path, so a
shared dependency always resolves from the bundle and the two never disagree on a version. If an app update
changes requirements-voice.txt, the marker no longer matches and Settings offers to update the engine.

In a dev venv that has mlx-audio installed directly, the runtime reports itself as `builtin` and none of this runs.
"""
from __future__ import annotations

import hashlib
import importlib
import json
import os
import shutil
import site
import subprocess
import sys
import threading
import time
from importlib.util import find_spec
from pathlib import Path
from typing import Callable

from . import download as DL
from . import tiers as T

PY_TAG = f"py{sys.version_info.major}{sys.version_info.minor}"
ROOT = Path(os.environ.get("LG_TTS_RUNTIME_DIR", T.APP_SUPPORT_DIR / "runtimes"))
DIR = ROOT / f"voice-{PY_TAG}"
WHEELS = ROOT / ".downloads" / f"voice-{PY_TAG}"
STAGING = ROOT / f".staging-voice-{PY_TAG}"
MARKER = "lg_runtime.json"
LOCK = Path(__file__).resolve().parent.parent / "requirements-voice.txt"

# Shown before the first resolve, which measures the real numbers. Measured 2026-10-13 for cp314 / arm64.
DOWNLOAD_ESTIMATE = 121_000_000
INSTALLED_ESTIMATE = 540_000_000

# Whether mlx-audio is importable from the bundle itself (a dev venv). Decided before we touch sys.path.
BUILTIN = find_spec("mlx_audio") is not None


def lock_digest() -> str:
    """Hash of the pins (comments ignored), so a reworded comment doesn't force a reinstall."""
    pins = [line.strip() for line in LOCK.read_text().splitlines()
            if line.strip() and not line.lstrip().startswith("#")]
    return hashlib.sha256("\n".join(sorted(pins)).encode()).hexdigest()


def _marker() -> dict | None:
    try:
        return json.loads((DIR / MARKER).read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def installed() -> bool:
    m = _marker()
    return m is not None and m.get("lock") == lock_digest()


def outdated() -> bool:
    m = _marker()
    return m is not None and m.get("lock") != lock_digest()


def ready() -> bool:
    """Can the QUALITY tiers import mlx-audio right now?"""
    return BUILTIN or installed()


def activate() -> None:
    """Put an installed runtime on sys.path (appended, so the bundle's own packages win)."""
    if BUILTIN or not installed() or str(DIR) in sys.path:
        return
    site.addsitedir(str(DIR))
    importlib.invalidate_caches()


def deactivate() -> None:
    if str(DIR) in sys.path:
        sys.path.remove(str(DIR))
    importlib.invalidate_caches()


def remove() -> None:
    """Delete the runtime and anything it left behind. Modules already imported stay loaded until restart."""
    deactivate()
    for path in (DIR, WHEELS, STAGING):
        shutil.rmtree(path, ignore_errors=True)


def _pip(args: list[str], cancel: threading.Event, what: str) -> str:
    """Run pip in this interpreter, killable by `cancel`. Returns stdout; raises DownloadError on failure."""
    # The app runs the sidecar with PYTHONDONTWRITEBYTECODE (its folder is inside the signed bundle). The
    # runtime lives in Application Support, so let pip precompile it: transformers imports far faster that way.
    env = {k: v for k, v in os.environ.items() if k != "PYTHONDONTWRITEBYTECODE"}
    proc = subprocess.Popen([sys.executable, "-m", "pip", *args, "--disable-pip-version-check"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                            env={**env, "PIP_NO_INPUT": "1"})
    while proc.poll() is None:
        if cancel.wait(0.2):
            proc.kill()
            proc.wait()
            raise DL.Cancelled()
    out, err = proc.communicate()
    if proc.returncode != 0:
        tail = (err or out).strip().splitlines()[-3:]
        raise DL.DownloadError(f"Couldn't {what}: {' '.join(tail) or f'pip exited {proc.returncode}'}")
    return out


def resolve(cancel: threading.Event) -> list[tuple[str, Path, int, str]]:
    """(url, wheel path, size, sha256) for every pinned wheel, chosen for this interpreter."""
    WHEELS.mkdir(parents=True, exist_ok=True)
    report = WHEELS / "report.json"
    _pip(["install", "--dry-run", "--ignore-installed", "--no-deps", "--only-binary=:all:", "--quiet",
          "--report", str(report), "-r", str(LOCK)], cancel, "look up the voice engine's packages")
    items = []
    for entry in json.loads(report.read_text())["install"]:
        info = entry["download_info"]
        url = info["url"]
        sha = info.get("archive_info", {}).get("hashes", {}).get("sha256", "")
        if cancel.is_set():
            raise DL.Cancelled()
        items.append((url, WHEELS / url.rsplit("/", 1)[-1], DL.content_length(url), sha))
    if not items:
        raise DL.DownloadError("requirements-voice.txt resolved to nothing")
    return items


def install(cancel: threading.Event, on_total: Callable[[int, int], None],
            on_bytes: Callable[[int], None], on_phase: Callable[[str], None]) -> None:
    """Resolve, download and install the runtime, then activate it. Raises Cancelled / DownloadError."""
    on_phase("resolving")
    items = resolve(cancel)
    triples = [(url, path, size) for url, path, size, _ in items]
    on_total(sum(size for *_, size in triples), DL.bytes_on_disk_items(triples))

    on_phase("downloading")
    DL.fetch_urls(triples, cancel, on_bytes)
    for _, path, _, sha in items:
        if sha and hashlib.sha256(path.read_bytes()).hexdigest() != sha:
            path.unlink(missing_ok=True)       # a bad wheel is re-fetched on the next try
            raise DL.DownloadError(f"{path.name} failed its checksum — try again.")

    on_phase("installing")
    shutil.rmtree(STAGING, ignore_errors=True)
    _pip(["install", "--no-index", "--no-deps", "--only-binary=:all:", "--quiet", "--target", str(STAGING),
          *[str(path) for _, path, _, _ in items]], cancel, "install the voice engine")
    (STAGING / MARKER).write_text(json.dumps({
        "lock": lock_digest(), "python": PY_TAG, "installed": time.time(),
        "packages": [path.name for _, path, _, _ in items]}))
    deactivate()
    shutil.rmtree(DIR, ignore_errors=True)
    os.replace(STAGING, DIR)
    shutil.rmtree(WHEELS, ignore_errors=True)            # ~120 MB that's no longer needed
    try:
        WHEELS.parent.rmdir()                             # .downloads/, if nothing else is in it
    except OSError:
        pass
    for other in ROOT.glob("voice-py*"):                  # runtimes for a Python the app no longer ships
        if other != DIR:
            shutil.rmtree(other, ignore_errors=True)
    activate()


def status() -> dict:
    return {"builtin": BUILTIN, "installed": ready(), "outdated": not BUILTIN and outdated(),
            "download_bytes": DOWNLOAD_ESTIMATE, "installed_bytes": INSTALLED_ESTIMATE, "python": PY_TAG}
