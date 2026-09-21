"""Alice's neural voice: Qwen3-TTS (Base, cloned) on MLX, in-process in the sidecar.

Why in the sidecar and not the app: MLX is a Python runtime here, and the sidecar already *is* the Python
host (integration shape A in the design_alice_acoustic_voice memory). Swift stays the surface: it asks for
audio over HTTP and plays what comes back (Invariant #3).

Shape of the thing:

- **One MLX thread.** Loading, generating and unloading all run on a single worker thread. That
  serialises every GPU operation without a lock and keeps MLX's per-thread stream state consistent.
- **Streaming, always.** `streaming_interval=0.5` is not a latency nicety — it is the memory fix. The
  non-streaming path's peak grows with the text (4.2 → 9.9 GB for 2 → 780 chars on 1.7B); streaming
  holds it flat, and 0.5 s is lower than the library's 2.0 s default on BOTH memory and first audio.
- **Cloned, never designed.** Alice is a reference clip + its transcript. VoiceDesign re-rolls the speaker
  every call; Base + a fixed clip is the same person every time (speaker cosine ~0.997 across tiers).
- **Pre-emptive.** Only one voice at a time. A new request cancels the one in flight; the old producer
  notices between codec chunks (≤ one `streaming_interval` of audio) and stops.
- **Kept warm, then released.** The model stays loaded for `KEEP_ALIVE_S` after last use, like Ollama's
  `keep_alive`, then unloads. A warm 6-bit reload measured 0.3 s, so releasing idle memory is cheap.
  `unload()` is public for anything that needs the memory now — image generation evicts the voice
  before the chat model because the voice is ~50× cheaper to bring back.

Speed is NOT handled here: Qwen3-TTS has no speed control (`generate(speed=)` is accepted and ignored).
The app applies the user's rate at playback with `AVAudioUnitTimePitch`.
"""
from __future__ import annotations

import asyncio
import gc
import json
import shutil
import threading
import time
import wave
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import AsyncIterator

from . import tiers as T
from .text import chunk, language_for

SAMPLE_RATE = 24_000
# 0.3 was the audition setting. Temperature costs no memory (measured byte-identical peaks 0.0–0.9);
# 0.0 is bit-identical every take but would freeze the small variations Yogi preferred, and dry wit —
# Alice's signature register — was the one register whose takes differed, so keep it above zero.
TEMPERATURE = 0.3
STREAMING_INTERVAL = 0.5
KEEP_ALIVE_S = 600


class VoiceError(Exception):
    """A failure the app should show as-is (no reference clip, tier not installed, …)."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


@dataclass
class _Job:
    cancelled: threading.Event = field(default_factory=threading.Event)


@dataclass
class _Download:
    state: str = "idle"          # idle | running | done | error
    done_bytes: int = 0
    total_bytes: int = 0
    error: str | None = None


class VoiceService:
    def __init__(self) -> None:
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="tts-mlx")
        self._model = None
        self._loaded_tier: str | None = None
        self._reference = None           # mx.array, cached for the loaded model
        self._reference_text: str | None = None
        self._job: _Job | None = None
        self._last_used = 0.0
        self._idle_task: asyncio.Task | None = None
        self._downloads: dict[str, _Download] = {}
        self._import_error: str | None = None
        self._resident_gb = 0.0

    # ------------------------------------------------------------------ status

    def available(self) -> tuple[bool, str | None]:
        """Whether MLX + mlx-audio are installed. Checked with find_spec, NOT import: importing mlx_audio
        pulls in transformers (~2 s), and this runs on the event loop — a real import here would stall a
        concurrent /chat stream. The real import happens on the MLX thread at load time."""
        if self._import_error is None:
            from importlib.util import find_spec
            missing = [m for m in ("mlx", "mlx_audio") if find_spec(m) is None]
            self._import_error = f"not installed: {', '.join(missing)}" if missing else ""
        return (not self._import_error), (self._import_error or None)

    def status(self) -> dict:
        ok, why = self.available()
        return {
            "available": ok,
            "unavailable_reason": why,
            "reference": {
                "present": T.REFERENCE_AUDIO.exists() and T.REFERENCE_TEXT.exists(),
                "audio": str(T.REFERENCE_AUDIO),
                "text": str(T.REFERENCE_TEXT),
            },
            "loaded_tier": self._loaded_tier,
            "resident_gb": round(self._resident_gb, 2),
            "sample_rate": SAMPLE_RATE,
            "tiers": {
                t.id: {
                    "label": t.label,
                    "engine": t.engine,
                    "repo": t.repo,
                    "installed": t.is_installed(),
                    "download_bytes": t.download_bytes,
                    "resident_gb": t.resident_gb,
                    "peak_gb": t.peak_gb,
                    "download": self._download_status(t.id),
                }
                for t in T.TIERS.values()
            },
        }

    # ------------------------------------------------------------------ worker-thread operations

    def _load_reference(self):
        import mlx.core as mx
        import numpy as np

        if not (T.REFERENCE_AUDIO.exists() and T.REFERENCE_TEXT.exists()):
            raise VoiceError("no_reference",
                             f"Alice's voice clip is missing — expected {T.REFERENCE_AUDIO} and "
                             f"{T.REFERENCE_TEXT.name} beside it.")
        with wave.open(str(T.REFERENCE_AUDIO), "rb") as w:
            if w.getframerate() != SAMPLE_RATE or w.getnchannels() != 1 or w.getsampwidth() != 2:
                raise VoiceError("bad_reference",
                                 "The voice clip must be 24 kHz mono 16-bit WAV.")
            pcm = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
        text = T.REFERENCE_TEXT.read_text(encoding="utf-8").strip()
        if not text:
            raise VoiceError("bad_reference", "The voice clip's transcript is empty.")
        return mx.array(pcm), text

    def _load_sync(self, tier_id: str) -> dict:
        import mlx.core as mx
        from mlx_audio.tts.utils import load_model

        tier = T.tier(tier_id)
        if tier.engine != "mlx":
            raise VoiceError("wrong_engine", f"{tier.label} runs in the app, not the sidecar.")
        if self._loaded_tier == tier_id and self._model is not None:
            return {"tier": tier_id, "load_s": 0.0, "already_loaded": True}
        if not tier.is_installed():
            raise VoiceError("not_installed", f"{tier.label} isn't downloaded yet.")
        self._unload_sync()
        started = time.time()
        reference, reference_text = self._load_reference()
        self._model = load_model(str(tier.path))
        self._reference, self._reference_text = reference, reference_text
        self._loaded_tier = tier_id
        load_s = time.time() - started
        # One throwaway generation compiles the kernels, so the first real sentence doesn't pay for it.
        warm_started = time.time()
        for _ in self._model.generate(text="Hello.", ref_audio=self._reference,
                                      ref_text=self._reference_text, lang_code="english",
                                      stream=True, streaming_interval=STREAMING_INTERVAL,
                                      temperature=TEMPERATURE):
            pass
        self._resident_gb = mx.get_active_memory() / 1e9
        return {"tier": tier_id, "load_s": round(load_s, 2),
                "warmup_s": round(time.time() - warm_started, 2),
                "resident_gb": round(self._resident_gb, 2)}

    def _unload_sync(self) -> bool:
        if self._model is None:
            return False
        import mlx.core as mx

        self._model = None
        self._reference = None
        self._reference_text = None
        self._loaded_tier = None
        self._resident_gb = 0.0
        gc.collect()
        mx.clear_cache()
        return True

    def _produce_sync(self, pieces: list[str], job: _Job, emit) -> None:
        """Generate every piece, handing int16 PCM bytes to `emit` as each codec chunk lands."""
        import numpy as np

        for piece in pieces:
            if job.cancelled.is_set():
                return
            for result in self._model.generate(
                text=piece, ref_audio=self._reference, ref_text=self._reference_text,
                lang_code=language_for(piece), stream=True,
                streaming_interval=STREAMING_INTERVAL, temperature=TEMPERATURE,
            ):
                if job.cancelled.is_set():
                    return
                audio = np.asarray(result.audio, dtype=np.float32).reshape(-1)
                emit((np.clip(audio, -1.0, 1.0) * 32767).astype("<i2").tobytes())

    # ------------------------------------------------------------------ async API

    async def _run(self, fn, *args):
        return await asyncio.get_running_loop().run_in_executor(self._executor, fn, *args)

    async def prepare(self, tier_id: str) -> dict:
        ok, why = self.available()
        if not ok:
            raise VoiceError("unavailable", why or "MLX is not available")
        result = await self._run(self._load_sync, tier_id)
        self._touch()
        return result

    async def unload(self) -> bool:
        self.cancel()
        return await self._run(self._unload_sync)

    def cancel(self) -> None:
        if self._job is not None:
            self._job.cancelled.set()

    async def speak(self, text: str, tier_id: str) -> AsyncIterator[bytes]:
        """Stream Alice saying `text` as little-endian int16 mono PCM at SAMPLE_RATE.

        Loading happens here if needed, BEFORE the first byte — so a caller that awaits the first chunk
        sees load errors as exceptions rather than as a truncated stream."""
        pieces = chunk(text)
        if not pieces:
            return
        self.cancel()                         # one voice at a time
        job = _Job()
        self._job = job
        await self.prepare(tier_id)

        loop = asyncio.get_running_loop()
        queue: asyncio.Queue = asyncio.Queue()
        done = object()

        def emit(data: bytes) -> None:
            loop.call_soon_threadsafe(queue.put_nowait, data)

        def produce() -> None:
            try:
                self._produce_sync(pieces, job, emit)
            except Exception as e:           # surfaced to the consumer below
                loop.call_soon_threadsafe(queue.put_nowait, e)
            finally:
                loop.call_soon_threadsafe(queue.put_nowait, done)

        future = loop.run_in_executor(self._executor, produce)
        try:
            while True:
                item = await queue.get()
                if item is done:
                    break
                if isinstance(item, Exception):
                    raise item
                self._touch()
                yield item
        finally:
            # Reached on completion AND on client disconnect (the response generator is closed). Either
            # way the producer must stop; it checks the flag between codec chunks.
            job.cancelled.set()
            if self._job is job:
                self._job = None
            self._touch()
            future.add_done_callback(lambda f: f.exception())   # never leave an unretrieved exception

    # ------------------------------------------------------------------ idle release

    def _touch(self) -> None:
        self._last_used = time.time()
        if self._idle_task is None or self._idle_task.done():
            self._idle_task = asyncio.get_running_loop().create_task(self._idle_watch())

    async def _idle_watch(self) -> None:
        while self._model is not None:
            remaining = self._last_used + KEEP_ALIVE_S - time.time()
            if remaining <= 0 and self._job is None:
                await self._run(self._unload_sync)
                print(f"[tts] voice unloaded after {KEEP_ALIVE_S}s idle")
                return
            await asyncio.sleep(max(5.0, remaining))

    # ------------------------------------------------------------------ downloads

    def _download_status(self, tier_id: str) -> dict:
        d = self._downloads.get(tier_id)
        if d is None:
            return {"state": "idle", "done_bytes": 0, "total_bytes": 0, "error": None}
        if d.state == "running":
            d.done_bytes = _dir_bytes(T.tier(tier_id).path)
        return {"state": d.state, "done_bytes": min(d.done_bytes, d.total_bytes or d.done_bytes),
                "total_bytes": d.total_bytes, "error": d.error}

    def start_download(self, tier_id: str) -> dict:
        tier = T.tier(tier_id)
        current = self._downloads.get(tier_id)
        if current is not None and current.state == "running":
            return self._download_status(tier_id)
        if tier.is_installed():
            self._downloads[tier_id] = _Download(state="done", done_bytes=tier.download_bytes,
                                                 total_bytes=tier.download_bytes)
            return self._download_status(tier_id)
        d = _Download(state="running", total_bytes=tier.download_bytes)
        self._downloads[tier_id] = d
        threading.Thread(target=self._download_sync, args=(tier, d), daemon=True,
                         name=f"tts-download-{tier_id}").start()
        return self._download_status(tier_id)

    def _download_sync(self, tier: T.Tier, d: _Download) -> None:
        try:
            from huggingface_hub import snapshot_download

            tier.path.mkdir(parents=True, exist_ok=True)
            snapshot_download(repo_id=tier.repo, revision=tier.revision, local_dir=str(tier.path),
                              allow_patterns=list(tier.allow_patterns) if tier.allow_patterns else None)
            missing = [f for f in tier.required if not (tier.path / f).exists()]
            if missing:
                raise RuntimeError(f"download finished but {', '.join(missing)} is missing")
            (tier.path / T.COMPLETE_MARKER).write_text(json.dumps(
                {"repo": tier.repo, "revision": tier.revision, "completed": time.time()}))
            d.done_bytes = tier.download_bytes
            d.state = "done"
        except Exception as e:
            d.state = "error"
            d.error = f"{type(e).__name__}: {e}"

    def delete(self, tier_id: str) -> bool:
        tier = T.tier(tier_id)
        if self._loaded_tier == tier_id:
            raise VoiceError("in_use", f"{tier.label} is loaded — unload it first.")
        d = self._downloads.get(tier_id)
        if d is not None and d.state == "running":
            raise VoiceError("downloading", f"{tier.label} is still downloading.")
        if tier.path.is_symlink():            # a dev link to an existing snapshot — never delete through it
            tier.path.unlink()
            return True
        if tier.path.exists():
            shutil.rmtree(tier.path)
            self._downloads.pop(tier_id, None)
            return True
        return False


def _dir_bytes(path) -> int:
    try:
        return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())
    except FileNotFoundError:
        return 0


voice = VoiceService()
