"""Image generation: model downloads, and running the `lg-imagegen` helper beside Alice.

**One image at a time, one process per image.** The helper loads FLUX.2 [klein] from Core AI's specialization
cache (~0.6 s warm), generates, writes the PNG and exits, so its ~6.8 GB is back with the system the moment the
image exists. Nothing stays resident between requests.

**Making room (design §6.3, decided 2026-09-19: automatic, not a setting).** On a 32 GB Mac, Alice (gemma4:26b,
~18 GB) + Klein (6.8 GB) + macOS and open apps can exceed physical memory; measured, macOS then swaps Alice out
and her next reply is 5.7× slower. So before each image we check the headroom, and if it's short we free memory
in order of cost to bring back: the QUALITY voice first (reloads in ~0.3 s), then the chat model (~15 s). Alice
reloads by herself on her next reply.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import re
import secrets
import shutil
import subprocess
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

import httpx

from tts import download as DL
from . import models as M

GENERATE_TIMEOUT_S = 300
MARGIN_GB = 1.5               # headroom kept free beyond the image's peak


class ImageGenError(Exception):
    """A failure Alice should report as-is."""


@dataclass
class _Download:
    state: str = "idle"          # idle | running | done | error | cancelled
    phase: str | None = None     # downloading | verifying
    done_bytes: int = 0
    total_bytes: int = 0
    error: str | None = None
    cancel: threading.Event = field(default_factory=threading.Event)


class ImageGenService:
    def __init__(self) -> None:
        self._downloads: dict[str, _Download] = {}
        self._lock = asyncio.Lock()          # one generation at a time
        self._gpu_budget: int | None = None
        self._generating = False

    # ------------------------------------------------------------------ status

    def available(self) -> tuple[bool, str | None]:
        if not M.os_supported():
            return False, "Image generation needs macOS 27."
        if M.helper_path() is None:
            return False, "The image generator helper is missing from this build."
        return True, None

    def status(self) -> dict:
        ok, why = self.available()
        return {
            "available": ok,
            "unavailable_reason": why,
            "generating": self._generating,
            "models": {
                m.id: {
                    "label": m.label,
                    "installed": m.is_installed(),
                    "download_bytes": m.download_bytes,
                    "peak_gb": m.peak_gb,
                    "license": m.license,
                    "source": m.source,
                    "download": self._download_status(m.id),
                }
                for m in M.MODELS.values()
            },
        }

    def _download_status(self, model_id: str) -> dict:
        d = self._downloads.get(model_id)
        if d is None:
            return {"state": "idle", "phase": None, "done_bytes": 0, "total_bytes": 0, "error": None}
        return {"state": d.state, "phase": d.phase, "done_bytes": min(d.done_bytes, d.total_bytes or d.done_bytes),
                "total_bytes": d.total_bytes, "error": d.error}

    # ------------------------------------------------------------------ downloads

    def start_download(self, model_id: str) -> dict:
        m = M.model(model_id)
        current = self._downloads.get(model_id)
        if current is not None and current.state == "running":
            return self._download_status(model_id)
        if m.is_installed():
            self._downloads[model_id] = _Download(state="done", done_bytes=m.download_bytes,
                                                  total_bytes=m.download_bytes)
            return self._download_status(model_id)
        d = _Download(state="running", total_bytes=m.download_bytes)
        self._downloads[model_id] = d
        threading.Thread(target=self._download_sync, args=(m, d), daemon=True,
                         name=f"imagegen-download-{model_id}").start()
        return self._download_status(model_id)

    def cancel_download(self, model_id: str) -> dict:
        M.model(model_id)
        d = self._downloads.get(model_id)
        if d is not None and d.state == "running":
            d.cancel.set()
        return self._download_status(model_id)

    def _download_sync(self, m: M.ImageModel, d: _Download) -> None:
        try:
            m.path.mkdir(parents=True, exist_ok=True)
            shutil.rmtree(m.path / ".cache", ignore_errors=True)
            files = DL.list_files(m.repo, m.revision, None)
            sums = DL.lfs_checksums(m.repo, m.revision)
            d.total_bytes = sum(size for _, size in files) or m.download_bytes
            d.done_bytes = DL.bytes_on_disk(m.path, files)
            d.phase = "downloading"

            def on_bytes(n: int) -> None:
                d.done_bytes += n

            DL.fetch(m.repo, m.revision, files, m.path, d.cancel, on_bytes)
            d.phase = "verifying"
            for path, expected in sums.items():
                if d.cancel.is_set():
                    raise DL.Cancelled()
                target = m.path / path
                if _sha256(target, d.cancel) != expected:
                    target.unlink(missing_ok=True)        # re-fetched on the next Download
                    raise DL.DownloadError(f"{path} failed its checksum — press Download to fetch it again.")
            missing = [f for f in m.required if not (m.path / f).exists()]
            if missing:
                raise DL.DownloadError(f"download finished but {', '.join(missing)} is missing")
            (m.path / M.COMPLETE_MARKER).write_text(json.dumps(
                {"repo": m.repo, "revision": m.revision, "completed": time.time()}))
            d.done_bytes = d.total_bytes
            d.state = "done"
        except DL.Cancelled:
            d.state = "cancelled"
        except DL.DownloadError as e:
            d.state, d.error = "error", str(e)
        except Exception as e:
            d.state, d.error = "error", f"{type(e).__name__}: {e}"
        finally:
            d.phase = None

    def delete(self, model_id: str) -> bool:
        m = M.model(model_id)
        if self._generating:
            raise ImageGenError("An image is being generated — try again when it's done.")
        d = self._downloads.get(model_id)
        if d is not None and d.state == "running":
            raise ImageGenError(f"{m.label} is still downloading.")
        if not m.path.exists():
            return False
        # Core AI's specialized copy is about the model's size and is never reclaimed on its own: clear it first,
        # through the helper (the cache is per process name, and the helper is the one that built it).
        helper = M.helper_path()
        if helper is not None:
            subprocess.run([str(helper), "--clear-cache", "--model", str(m.path)],
                           capture_output=True, text=True, timeout=60)
        shutil.rmtree(m.path)
        self._downloads.pop(model_id, None)
        return True

    # ------------------------------------------------------------------ generation

    async def generate(self, prompt: str, output: Path, *, seed: int | None = None,
                       edit_image: Path | None = None, ollama_host: str, chat_model: str | None) -> dict:
        """Generate (or edit) one image into `output`. Returns the helper's result: path, seconds, seed, freed."""
        ok, why = self.available()
        if not ok:
            raise ImageGenError(why or "Image generation isn't available.")
        m = M.MODELS["klein"]
        if not m.is_installed():
            raise ImageGenError("Image generation isn't set up yet — download the image model in "
                                "Settings → System → Images.")
        seed = seed if seed is not None else secrets.randbelow(2**31)
        async with self._lock:
            self._generating = True
            try:
                freed = await self._make_room(m, ollama_host, chat_model)
                args = [str(M.helper_path()), "--model", str(m.path), "--prompt", prompt,
                        "--seed", str(seed), "--output", str(output)]
                if edit_image is not None:
                    args += ["--input-image", str(edit_image), "--reference-grid", "full"]
                result = await _run_helper(args)
                result.update(seed=seed, freed=freed)
                return result
            finally:
                self._generating = False

    async def _make_room(self, m: M.ImageModel, ollama_host: str, chat_model: str | None) -> list[str]:
        """Free GPU memory for the image if it won't fit beside what's loaded. Returns what was unloaded."""
        from tts.service import voice

        freed: list[str] = []
        need = m.peak_gb + MARGIN_GB
        budget = await self._budget_gb()

        def fits(ollama_gb: float, voice_gb: float) -> bool:
            return (_available_ram_gb() >= need) and (ollama_gb + voice_gb + need <= budget)

        ollama_gb = await _ollama_resident_gb(ollama_host)
        voice_gb = voice.status().get("resident_gb", 0.0) or 0.0
        print(f"[imagegen] room check: need {need:.1f} GB · free RAM {_available_ram_gb():.1f} GB · "
              f"GPU {ollama_gb + voice_gb:.1f}/{budget:.1f} GB (ollama {ollama_gb:.1f}, voice {voice_gb:.1f})", flush=True)
        if fits(ollama_gb, voice_gb):
            return freed
        if voice_gb > 0 and await voice.unload():
            freed.append("voice")
            voice_gb = 0.0
            if fits(ollama_gb, voice_gb):
                return freed
        if chat_model and await _ollama_unload(ollama_host, chat_model):
            freed.append(chat_model)
        print(f"[imagegen] freed for the image: {', '.join(freed) or 'nothing (no chat model known)'}", flush=True)
        return freed

    async def _budget_gb(self) -> float:
        """Metal's recommended GPU working set (26.8 GB on a 32 GB M1 Max), asked of the helper once."""
        if self._gpu_budget is None:
            try:
                result = await _run_helper([str(M.helper_path()), "--info"], expect="info")
                self._gpu_budget = int(result.get("gpu_budget_bytes") or 0)
            except ImageGenError:
                self._gpu_budget = 0
        return self._gpu_budget / 1e9 if self._gpu_budget else 0.0


# ---------------------------------------------------------------------- helpers

def _sha256(path: Path, cancel: threading.Event) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 24):
            if cancel.is_set():
                raise DL.Cancelled()
            h.update(chunk)
    return h.hexdigest()


async def _run_helper(args: list[str], expect: str = "done") -> dict:
    """Run the helper, follow its JSON lines, and return the final `expect` event (or raise its error).
    Both pipes are drained while it runs, so a chatty stderr can never block it."""
    proc = await asyncio.create_subprocess_exec(*args, stdout=asyncio.subprocess.PIPE,
                                                stderr=asyncio.subprocess.PIPE)
    final: dict | None = None
    error: str | None = None
    stderr_tail: list[str] = []

    async def read_stdout() -> None:
        nonlocal final, error
        assert proc.stdout is not None
        async for raw in proc.stdout:
            try:
                event = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if event.get("event") == expect:
                final = event
            elif event.get("event") == "error":
                error = event.get("message")

    async def read_stderr() -> None:
        assert proc.stderr is not None
        async for raw in proc.stderr:
            stderr_tail.append(raw.decode(errors="replace").rstrip())
            del stderr_tail[:-5]

    async def kill() -> None:
        if proc.returncode is None:
            proc.kill()
            await proc.wait()

    try:
        await asyncio.wait_for(asyncio.gather(read_stdout(), read_stderr(), proc.wait()), timeout=GENERATE_TIMEOUT_S)
    except asyncio.TimeoutError:
        await kill()
        raise ImageGenError(f"The image generator took over {GENERATE_TIMEOUT_S} s and was stopped.")
    except asyncio.CancelledError:
        await kill()                       # the chat was stopped: don't leave a 7 GB process behind
        raise
    if final is None:
        raise ImageGenError(error or (stderr_tail[-1] if stderr_tail else f"the generator exited {proc.returncode}"))
    return final


def _available_ram_gb() -> float:
    """Memory macOS can hand out without swapping: free + inactive + speculative + purgeable pages."""
    try:
        out = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return 0.0
    page = int(m.group(1)) if (m := re.search(r"page size of (\d+) bytes", out)) else 16384
    pages = 0
    for key in ("Pages free", "Pages inactive", "Pages speculative", "Pages purgeable"):
        if (m := re.search(rf"{key}:\s+(\d+)", out)):
            pages += int(m.group(1))
    return pages * page / 1e9


async def _ollama_resident_gb(host: str) -> float:
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            r = await client.get(f"{host}/api/ps")
            r.raise_for_status()
            return sum((m.get("size_vram") or m.get("size") or 0) for m in r.json().get("models", [])) / 1e9
    except (httpx.HTTPError, ValueError):
        return 0.0


async def _ollama_unload(host: str, name: str) -> bool:
    """Ask Ollama to drop a model now (keep_alive 0). It reloads on its own at the next request."""
    try:
        async with httpx.AsyncClient(timeout=30) as client:
            r = await client.post(f"{host}/api/generate", json={"model": name, "keep_alive": 0})
            return r.status_code == 200
    except httpx.HTTPError:
        return False


service = ImageGenService()
