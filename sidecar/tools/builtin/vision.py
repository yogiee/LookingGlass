"""describe_image — vision tool backed by qwen2.5vl:3b.

Makes a separate, non-streaming Ollama call using the request's Ollama host
(via contextvar). Alice's main model stays loaded; the vision model is loaded
only for the duration of the tool call, avoiding a double model-swap.

Model: qwen2.5vl:3b — BenchLLAMA Vision battery 2026-06-13 composite 1.00
(perfect OCR/count/chart/spatial/describe) at 129 tok/s / 3.2GB, beating the
prior gemma4:latest (0.767). Non-reasoning VLM, so think:False is a harmless
no-op (cf. qwen3-vl, whose unkillable thinking made it unusable here).
num_ctx matches the benched 16384 to avoid truncating image tokens on dense
images / OCR; the model is tiny so the RAM cost is negligible.
"""
import base64
from pathlib import Path

import httpx

from ..base import Tool, err, ok
from ..context import ollama_host as get_ollama_host

_VISION_MODEL = "qwen2.5vl:3b"
_SYSTEM_PROMPT = (
    "You are a precise visual analysis assistant. "
    "Look carefully at the image and answer."
)
_DEFAULT_PROMPT = "Describe this image in detail."


async def _describe_image(args: dict) -> dict:
    path_str = (args.get("path") or "").strip()
    prompt = (args.get("prompt") or _DEFAULT_PROMPT).strip()

    if not path_str:
        return err("Missing required argument 'path'.")

    img_path = Path(path_str).expanduser()
    if not img_path.is_file():
        return err(f"Image file not found: {path_str}")

    try:
        img_b64 = base64.b64encode(img_path.read_bytes()).decode("ascii")
    except Exception as e:
        return err(f"Could not read image file: {e}")

    host = get_ollama_host()
    payload = {
        "model": _VISION_MODEL,
        "messages": [
            {"role": "system", "content": _SYSTEM_PROMPT},
            {"role": "user", "content": prompt, "images": [img_b64]},
        ],
        "stream": False,
        "think": False,
        "options": {"num_ctx": 16384},
    }

    try:
        async with httpx.AsyncClient(timeout=120.0) as client:
            r = await client.post(f"{host}/api/chat", json=payload)
            if r.status_code >= 400:
                detail = r.text[:400]
                return err(f"Ollama HTTP {r.status_code}: {detail}")
            data = r.json()
            content = data.get("message", {}).get("content", "").strip()
            if not content:
                return err("Vision model returned an empty response.")
            return ok(content)
    except httpx.ConnectError:
        return err(f"Ollama not reachable at {host}")
    except Exception as e:
        return err(f"{type(e).__name__}: {e}")


TOOLS = [
    Tool(
        name="describe_image",
        description=(
            "Read and describe an image file. Call this when the user's message "
            "contains [Image: /path/to/file] — use that exact path as the `path` "
            "argument. Use the optional `prompt` to tailor the response: "
            "'Extract all text from this image' for OCR, "
            "'What does this diagram show?' for technical drawings, etc."
        ),
        parameters={
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Absolute path to the image file",
                },
                "prompt": {
                    "type": "string",
                    "description": (
                        "What to ask about the image. "
                        "Defaults to a general description."
                    ),
                },
            },
            "required": ["path"],
        },
        handler=_describe_image,
        category="vision",
    ),
]
