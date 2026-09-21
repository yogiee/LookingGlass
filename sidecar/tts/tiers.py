"""The Qwen3-TTS voice tiers and where their files live.

Two of the three voice tiers run here, in the sidecar, on MLX: QUALITY (0.6B) and QUALITY+ (1.7B). The
third, LIGHT (Kokoro-82M), runs IN THE SWIFT APP on Core AI — but it is listed here too, as a download-only
tier, so all three voices share one downloader, one install check and one progress UI. The sidecar never
loads or runs LIGHT (`engine="coreai"`); `/tts/prepare` and `/tts/speak` refuse it.

Both Qwen tiers are the **Base** model — the voice-cloning variant — at **6-bit**. 4-bit was rejected by
ear: every 4-bit sample, at both sizes, has an audible glitch on its first word. Revisions are pinned to
the exact snapshots that were auditioned, so a user downloads the bytes that were judged, not whatever
`main` has become since.

Every file here is USER DATA (Invariant #7): models and the reference voice live in Application Support,
never in the app bundle, so an update can't wipe a multi-gigabyte download.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

APP_SUPPORT_DIR = Path.home() / "Library" / "Application Support" / "LookingGlass"

# Dev/test overrides. Unset in the shipped app.
MODELS_DIR = Path(os.environ.get("LG_TTS_MODELS_DIR", APP_SUPPORT_DIR / "models" / "tts"))
VOICE_DIR = Path(os.environ.get("LG_TTS_VOICE_DIR", APP_SUPPORT_DIR / "voice"))

# Alice's voice: a reference clip and its exact transcript. They are a PAIR — cloning treats the clip as
# the opening of a continuation, so a transcript that runs past the audio makes the model speak the
# missing words first (see the gotcha_qwen_icl_reference_transcript_mismatch memory).
REFERENCE_AUDIO = VOICE_DIR / "alice_reference.wav"
REFERENCE_TEXT = VOICE_DIR / "alice_reference.txt"

# Written by our downloader once every file is in place. Its absence means "not installed", even if
# some files are present from an interrupted download.
COMPLETE_MARKER = "lg_tts_complete.json"

# Files a Qwen tier cannot load without. Used to accept a model directory that was populated some other
# way (a dev symlink to an existing Hugging Face snapshot) and therefore has no marker.
QWEN_REQUIRED = (
    "config.json",
    "model.safetensors",
    "speech_tokenizer/config.json",
    "speech_tokenizer/model.safetensors",
)

KOKORO_REQUIRED = (
    "kokoro_predictor.aimodel/main.mlirb",
    "kokoro_prosody.aimodel/main.mlirb",
    "kokoro_vocoder.aimodel/main.mlirb",
    "kokoro_host_glue/vocab.json",
    "kokoro_host_glue/l_linear.bin",
    "kokoro_host_glue/us_gold.json",
    "kokoro_host_glue/us_silver.json",
    "kokoro_host_glue/voices/bf_alice.bin",
)


@dataclass(frozen=True)
class Tier:
    id: str                  # matches the Swift VoiceTier raw value
    label: str               # what Settings shows
    repo: str
    revision: str
    download_bytes: int      # sum of the pinned revision's files we actually fetch
    # Measured on an M1 Max 32 GB at streaming_interval 0.5 (2026-09-21). The Swift AUTO picker reads
    # these to decide what fits beside the chat model; keep them in step with any re-measurement.
    resident_gb: float       # weights, held while loaded
    peak_gb: float           # while synthesising a long reply
    engine: str = "mlx"      # "mlx": runs here. "coreai": runs in the app; we only download it.
    required: tuple[str, ...] = QWEN_REQUIRED
    allow_patterns: tuple[str, ...] | None = None   # None = the whole snapshot

    @property
    def path(self) -> Path:
        return MODELS_DIR / self.id

    def is_installed(self) -> bool:
        if (self.path / COMPLETE_MARKER).exists():
            return True
        return all((self.path / f).exists() for f in self.required)


TIERS: dict[str, Tier] = {
    # Kokoro-82M on Core AI (Apache-2.0). Only the three graphs + the host glue: the repo's top-level
    # voices/ duplicates kokoro_host_glue/voices/, so it is skipped. Memory is CPU-side (Core AI .cpuOnly),
    # so it never competes with the chat model for the Metal budget.
    "light": Tier(
        id="light",
        label="LIGHT",
        repo="mlboydaisuke/Kokoro-82M-CoreAI",
        revision="556dda7f7c041bac3f64acb3a320847f4bc34fb3",
        download_bytes=360_532_098,
        resident_gb=0.83,
        peak_gb=0.83,
        engine="coreai",
        required=KOKORO_REQUIRED,
        allow_patterns=("kokoro_host_glue/*", "kokoro_predictor.aimodel/*",
                        "kokoro_prosody.aimodel/*", "kokoro_vocoder.aimodel/*"),
    ),
    "quality": Tier(
        id="quality",
        label="QUALITY",
        repo="mlx-community/Qwen3-TTS-12Hz-0.6B-Base-6bit",
        revision="4e44ed4bcee28a0f89a493e07bde16e6dccd43eb",
        download_bytes=1_851_312_607,
        resident_gb=1.93,
        peak_gb=2.72,
    ),
    "quality_plus": Tier(
        id="quality_plus",
        label="QUALITY+",
        repo="mlx-community/Qwen3-TTS-12Hz-1.7B-Base-6bit",
        revision="34ff5318365b59cba9c03ff729f2eee0814caf72",
        download_bytes=2_720_116_171,
        resident_gb=2.80,
        peak_gb=3.59,
    ),
}


def tier(tier_id: str) -> Tier:
    try:
        return TIERS[tier_id]
    except KeyError:
        raise ValueError(f"unknown voice tier '{tier_id}' (expected one of {', '.join(TIERS)})")
