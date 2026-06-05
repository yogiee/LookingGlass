import os

import httpx

from ..base import Tool, ok, err

# Jina Reader: converts any URL to clean readable markdown.
# Free without a key (rate-limited); set JINA_API_KEY for higher limits.
# If Jina is unreachable or returns an error, falls back to a plain HTTP fetch
# with a browser User-Agent so the tool still provides something useful.

JINA_BASE = "https://r.jina.ai/"
MAX_BODY = 60_000
_FALLBACK_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) "
    "Version/17.6 Safari/605.1.15"
)


async def _read_page(args: dict) -> dict:
    url = args.get("url")
    if not url:
        return err("Missing required argument: url")

    api_key = os.environ.get("JINA_API_KEY")
    headers = {"Accept": "text/markdown", "X-Return-Format": "markdown"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    jina_url = JINA_BASE + url

    try:
        async with httpx.AsyncClient(timeout=40.0, follow_redirects=True) as client:
            resp = await client.get(jina_url, headers=headers)
    except Exception as e:
        # Jina unreachable — fall back to plain fetch
        return await _fallback_fetch(url, str(e))

    if not resp.is_success:
        return await _fallback_fetch(url, f"Jina returned HTTP {resp.status_code}")

    text = resp.text
    if len(text) > MAX_BODY:
        text = text[:MAX_BODY] + f"\n\n[truncated at {MAX_BODY} chars]"

    return ok(text)


async def _fallback_fetch(url: str, reason: str) -> dict:
    try:
        async with httpx.AsyncClient(timeout=30.0, follow_redirects=True) as client:
            resp = await client.get(url, headers={"User-Agent": _FALLBACK_UA})
        text = resp.text
        if len(text) > MAX_BODY:
            text = text[:MAX_BODY] + f"\n\n[truncated at {MAX_BODY} chars]"
        note = f"[Jina unavailable ({reason}) — raw HTML below]\n\n"
        return ok(note + text) if resp.is_success else err(note + text)
    except Exception as e:
        return err(f"Jina unavailable ({reason}); fallback also failed: {e}")


TOOLS = [
    Tool(
        name="read_page",
        description=(
            "Fetch a web page and return its content as clean, readable markdown. "
            "Use this to read articles, documentation, Wikipedia pages, blog posts, "
            "or any URL found in search results. Prefer this over http_request for "
            "human-readable web content."
        ),
        parameters={
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "The URL to read"},
            },
            "required": ["url"],
        },
        handler=_read_page,
        category="search",
    ),
]
