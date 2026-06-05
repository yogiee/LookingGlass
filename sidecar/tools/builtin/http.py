import httpx

from ..base import Tool, ok, err

MAX_BODY = 100_000

_DEFAULT_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) "
    "Version/17.6 Safari/605.1.15"
)


async def _http_request(args: dict) -> dict:
    url = args.get("url")
    if not url:
        return err("Missing required argument: url")
    method = (args.get("method") or "GET").upper()
    # Caller headers take precedence; default UA prevents 403s from sites like Wikipedia.
    headers = {"User-Agent": _DEFAULT_UA, **(args.get("headers") or {})}
    body = args.get("body")

    try:
        async with httpx.AsyncClient(timeout=30.0, follow_redirects=True) as client:
            resp = await client.request(method, url, headers=headers, content=body)
    except httpx.ConnectError:
        return err(f"Could not connect to {url}")
    except httpx.TimeoutException:
        return err(f"Request to {url} timed out")
    except Exception as e:
        return err(f"{type(e).__name__}: {e}")

    text = resp.text
    if len(text) > MAX_BODY:
        text = text[:MAX_BODY] + f"\n\n[truncated at {MAX_BODY} chars]"

    ctype = resp.headers.get("content-type", "")
    summary = f"HTTP {resp.status_code} {method} {url}\nContent-Type: {ctype}\n\n{text}"
    if resp.is_success:
        return ok(summary)
    return err(summary)


TOOLS = [
    Tool(
        name="http_request",
        description="Make an HTTP request and return the status, headers summary, and response body. Useful for APIs and fetching raw pages.",
        parameters={
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "The URL to request"},
                "method": {"type": "string", "description": "HTTP method (GET, POST, etc.). Default GET."},
                "headers": {"type": "object", "description": "Optional request headers"},
                "body": {"type": "string", "description": "Optional request body (for POST/PUT)"},
            },
            "required": ["url"],
        },
        handler=_http_request,
        category="network",
    ),
]
