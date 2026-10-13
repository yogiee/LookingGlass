"""generate_image — Alice's on-device image generator (FLUX.2 [klein] 4B on Core AI).

Replaces the OllamaMCP `local_image` path, dead since Ollama removed image generation (0.32.6). The work runs in
the `lg-imagegen` helper (see imagegen/service.py); this file is only the tool surface.

Registration is import-safe (registry.discover() imports every builtin with no try/except): the tool registers
only on macOS 27+ with the helper present. If the model isn't downloaded yet, the tool still registers and says
so, so Alice can tell the user how to turn it on rather than silently lacking the ability.

The `output_dir` parameter is what marks this as an image tool for agent.py (`_find_image_tool`,
`_sanitize_tool_args`, which overwrites it with the request's generated-imagery folder).
"""
from __future__ import annotations

import re
import time
from pathlib import Path

from imagegen import models as M
from imagegen.service import ImageGenError, service

from ..base import Tool, err, ok
from ..context import chat_model, ollama_host, output_subdir

_IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".webp", ".heic", ".tif", ".tiff", ".bmp", ".gif"}


def _slug(text: str) -> str:
    """Filename-safe and space-free: InlineImageView only renders paths without whitespace."""
    words = re.findall(r"[a-z0-9]+", text.lower())[:6]
    return "-".join(words)[:48] or "image"


async def _generate_image(args: dict) -> dict:
    prompt = (args.get("prompt") or "").strip()
    if not prompt:
        return err("generate_image needs a prompt describing the image.")

    edit = None
    if args.get("edit_image"):
        edit = Path(str(args["edit_image"])).expanduser()
        if not edit.is_file():
            return err(f"edit_image: no image at {edit}. Pass the full path of an image shown earlier in the chat.")
        if edit.suffix.lower() not in _IMAGE_EXTS:
            return err(f"edit_image: {edit.name} isn't an image file.")

    seed = args.get("seed")
    try:
        seed = int(seed) if seed is not None and str(seed).strip() != "" else None
    except (TypeError, ValueError):
        return err("seed must be a whole number.")

    out_dir = Path(args.get("output_dir") or output_subdir("imagery")).expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = f"{time.strftime('%Y%m%d_%H%M%S')}_klein_{'edit_' if edit else ''}{_slug(prompt)}"
    output = out_dir / f"{stem}.png"

    try:
        result = await service.generate(prompt, output, seed=seed, edit_image=edit,
                                        ollama_host=ollama_host(), chat_model=chat_model())
    except ImageGenError as e:
        return err(str(e))
    # The path must be the LAST thing in the result: agent.py's voice plating and the inline renderer both key on
    # a trailing image path. Seed first, so a "same again but…" can reuse it.
    return ok(f"Seed {result['seed']}. {'Edited' if edit else 'Generated'} in {result.get('seconds', 0):.0f} s. "
              f"Image saved to {result['path']}")


TOOLS = []
if M.os_supported() and M.helper_path() is not None:
    TOOLS = [
        Tool(
            name="generate_image",
            description=(
                "Create an image on this Mac from a text description (FLUX.2 [klein], about 25 seconds), or EDIT "
                "an existing image: pass its full path as edit_image and describe the change "
                "(\"make it night\", \"add a red umbrella\"). The image appears to the user inline automatically "
                "— don't repeat the file path. Write a rich, concrete prompt: subject, setting, style, lighting, "
                "composition; put any text that must appear in the image in quotes."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "prompt": {"type": "string",
                               "description": "What to draw (or, with edit_image, what to change)."},
                    "edit_image": {"type": "string",
                                   "description": "Optional: full path of an earlier image to edit instead of "
                                                  "starting from scratch. Earlier images appear in the chat as "
                                                  "[Generated image: <path>] (yours) or [Image: <path>] (the user's)."},
                    "seed": {"type": "integer",
                             "description": "Optional: reuse a previous seed to get a close variation."},
                    "output_dir": {"type": "string",
                                   "description": "Leave empty; the app chooses the folder."},
                },
                "required": ["prompt"],
            },
            handler=_generate_image,
            category="media",
        ),
    ]
