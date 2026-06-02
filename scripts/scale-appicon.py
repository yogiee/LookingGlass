#!/usr/bin/env python3
"""Regenerate the macOS app icon with the standard transparent margin.

The hand-exported art is full-bleed (the squircle touches all four canvas
edges), which renders ~20% larger than neighbouring Dock / Cmd-Tab icons that
follow Apple's convention of a rounded-rect filling ~80% of the canvas. This
scales the master art onto a transparent 1024 canvas and re-emits every size.

Usage: python3 scripts/scale-appicon.py [scale]   # scale default 0.80
"""
import sys
from pathlib import Path
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
# Pristine full-bleed 1024 export — read-only source of truth, never written to,
# so this script is idempotent and re-runnable at any scale.
MASTER = REPO / "WORKSPACE/icons/LookingGlass-1024.png"
APPICONSET = REPO / "LookingGlass/Assets.xcassets/AppIcon.appiconset"
RUNTIME_ICON = REPO / "LookingGlass/Resources/appicon.png"

CANVAS = 1024
SCALE = float(sys.argv[1]) if len(sys.argv) > 1 else 0.80

# appiconset filename -> pixel dimension
SIZES = {
    "icon_16x16.png": 16,      "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,      "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,   "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,   "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,   "icon_512x512@2x.png": 1024,
}


def build_padded_master() -> Image.Image:
    """Scale the full-bleed master to SCALE and centre it on a clear canvas."""
    src = Image.open(MASTER).convert("RGBA")
    if src.size != (CANVAS, CANVAS):
        src = src.resize((CANVAS, CANVAS), Image.LANCZOS)
    inner = int(round(CANVAS * SCALE))
    art = src.resize((inner, inner), Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    off = (CANVAS - inner) // 2
    canvas.paste(art, (off, off), art)
    return canvas


def main():
    padded = build_padded_master()
    margin = (CANVAS - int(round(CANVAS * SCALE))) // 2
    print(f"scale={SCALE} → art {int(CANVAS*SCALE)}px on {CANVAS} canvas "
          f"({margin}px margin each side)")

    for name, px in SIZES.items():
        out = padded.resize((px, px), Image.LANCZOS)
        out.save(APPICONSET / name)
        print(f"  wrote {name} ({px}px)")

    padded.save(RUNTIME_ICON)
    print(f"  wrote {RUNTIME_ICON.relative_to(REPO)} (runtime Dock icon)")


if __name__ == "__main__":
    main()
