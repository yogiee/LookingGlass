"""Image models, the helper that runs them, and where both live.

The model is user data (Invariant #7): it downloads on request from Settings into Application Support and
survives app updates. The helper (`lg-imagegen`, ImageGenHelper/ in the repo) ships inside the app at
Contents/Helpers. Design: WORKSPACE/coreai-image-generation-design.md.
"""
from __future__ import annotations

import os
import platform
from dataclasses import dataclass
from pathlib import Path

APP_SUPPORT_DIR = Path.home() / "Library" / "Application Support" / "LookingGlass"
MODELS_DIR = Path(os.environ.get("LG_IMAGEGEN_MODELS_DIR", APP_SUPPORT_DIR / "models" / "coreai"))
COMPLETE_MARKER = "lg_model_complete.json"

SIDECAR_DIR = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class ImageModel:
    id: str
    label: str
    folder: str              # under MODELS_DIR
    repo: str
    revision: str            # pinned: the bytes we measured, never `main`
    download_bytes: int
    peak_gb: float           # measured helper peak (09-19 / 10-13, M1 Max): what has to fit beside Alice
    license: str
    source: str
    required: tuple[str, ...]

    @property
    def path(self) -> Path:
        return MODELS_DIR / self.folder

    def is_installed(self) -> bool:
        if (self.path / COMPLETE_MARKER).exists():
            return True
        # A bundle put in place some other way (the September eval) has every file but no marker.
        return all((self.path / f).exists() for f in self.required)


MODELS: dict[str, ImageModel] = {
    "klein": ImageModel(
        id="klein",
        label="FLUX.2 [klein] 4B",
        folder="FLUX.2-klein-4B",
        repo="DeadDuck123/FLUX.2-klein-4B-CoreAI",
        revision="9a1b6348b43fa69b6af2e3f82ae91601f019d8bc",
        download_bytes=4_279_000_000,
        peak_gb=6.8,
        license="Apache-2.0 · Black Forest Labs · converted for Core AI with Apple's coreai-models recipe",
        source="huggingface.co/DeadDuck123/FLUX.2-klein-4B-CoreAI",
        required=("metadata.json", "Transformer.aimodel", "TextEncoder.aimodel", "VAEDecoder.aimodel",
                  "VAEEncoder.aimodel", "tokenizer"),
    ),
}


def model(model_id: str) -> ImageModel:
    try:
        return MODELS[model_id]
    except KeyError:
        raise ValueError(f"unknown image model '{model_id}' (expected one of {', '.join(MODELS)})")


def helper_path() -> Path | None:
    """The `lg-imagegen` binary: inside the app, else a dev override, else the SwiftPM build in the repo."""
    candidates = [
        SIDECAR_DIR.parent.parent / "Helpers" / "lg-imagegen",          # Contents/Resources/sidecar → Contents/Helpers
        Path(os.environ["LG_IMAGEGEN_HELPER"]) if os.environ.get("LG_IMAGEGEN_HELPER") else None,
        SIDECAR_DIR.parent / ".build" / "release" / "lg-imagegen",      # `swift build -c release` in dev
    ]
    for c in candidates:
        if c is not None and c.is_file() and os.access(c, os.X_OK):
            return c
    return None


def os_supported() -> bool:
    """Core AI needs macOS 27."""
    try:
        return int(platform.mac_ver()[0].split(".")[0]) >= 27
    except (ValueError, IndexError):
        return False
