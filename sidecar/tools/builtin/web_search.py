import os

import httpx

from ..base import Tool, ok, err

# Cascade: SearXNG (self-hosted) → DuckDuckGo → Brave → Tavily.
# Each source is tried in order; the first to return results wins.
# Configure via env: SEARXNG_URL, BRAVE_API_KEY, TAVILY_API_KEY.


def _format(results: list[dict], source: str) -> str:
    if not results:
        return ""
    lines = [f"Search results (via {source}):\n"]
    for i, r in enumerate(results, 1):
        title = r.get("title", "Untitled")
        url = r.get("url", "")
        snippet = r.get("snippet", "").strip()
        lines.append(f"{i}. {title}\n   {url}\n   {snippet}\n")
    return "\n".join(lines)


async def _searxng(query: str, n: int, time_range: str | None = None) -> list[dict]:
    base = os.environ.get("SEARXNG_URL")
    if not base:
        return []
    try:
        params: dict = {"q": query, "format": "json"}
        if time_range:
            params["time_range"] = time_range
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.get(
                f"{base.rstrip('/')}/search",
                params=params,
            )
            resp.raise_for_status()
            data = resp.json()
        out = []
        for item in data.get("results", [])[:n]:
            out.append({
                "title": item.get("title", ""),
                "url": item.get("url", ""),
                "snippet": item.get("content", ""),
            })
        return out
    except Exception:
        return []


async def _duckduckgo(query: str, n: int) -> list[dict]:
    # Optional dependency — import lazily so the sidecar boots without it.
    try:
        from ddgs import DDGS
    except ImportError:
        try:
            from duckduckgo_search import DDGS  # older package name
        except ImportError:
            return []
    try:
        out = []
        with DDGS() as ddgs:
            for item in ddgs.text(query, max_results=n):
                out.append({
                    "title": item.get("title", ""),
                    "url": item.get("href", "") or item.get("url", ""),
                    "snippet": item.get("body", ""),
                })
        return out
    except Exception:
        return []


async def _brave(query: str, n: int) -> list[dict]:
    key = os.environ.get("BRAVE_API_KEY")
    if not key:
        return []
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.get(
                "https://api.search.brave.com/res/v1/web/search",
                params={"q": query, "count": n},
                headers={"X-Subscription-Token": key, "Accept": "application/json"},
            )
            resp.raise_for_status()
            data = resp.json()
        out = []
        for item in data.get("web", {}).get("results", [])[:n]:
            out.append({
                "title": item.get("title", ""),
                "url": item.get("url", ""),
                "snippet": item.get("description", ""),
            })
        return out
    except Exception:
        return []


async def _tavily(query: str, n: int) -> list[dict]:
    key = os.environ.get("TAVILY_API_KEY")
    if not key:
        return []
    try:
        async with httpx.AsyncClient(timeout=20.0) as client:
            resp = await client.post(
                "https://api.tavily.com/search",
                json={"api_key": key, "query": query, "max_results": n},
            )
            resp.raise_for_status()
            data = resp.json()
        out = []
        for item in data.get("results", [])[:n]:
            out.append({
                "title": item.get("title", ""),
                "url": item.get("url", ""),
                "snippet": item.get("content", ""),
            })
        return out
    except Exception:
        return []


async def _web_search(args: dict) -> dict:
    query = args.get("query")
    if not query:
        return err("Missing required argument: query")
    n = int(args.get("count", 5))
    time_range = args.get("recency")  # day | week | month | year — SearXNG only

    # SearXNG supports recency filtering; other backends get it as a hint in the query.
    if time_range and time_range not in ("day", "week", "month", "year"):
        return err("recency must be one of: day, week, month, year")

    results = await _searxng(query, n, time_range)
    if results:
        return ok(_format(results, "SearXNG"))

    # For non-SearXNG backends, append a recency hint to the query string.
    hinted = f"{query} after:{_recency_hint(time_range)}" if time_range else query
    for source, fn in [("DuckDuckGo", _duckduckgo), ("Brave", _brave), ("Tavily", _tavily)]:
        results = await fn(hinted, n)
        if results:
            return ok(_format(results, source))

    return err(
        "No search results. No search backend is available — install 'ddgs' "
        "(pip install ddgs), run SearXNG (set SEARXNG_URL), or set BRAVE_API_KEY / TAVILY_API_KEY."
    )


def _recency_hint(time_range: str | None) -> str:
    from datetime import date, timedelta
    today = date.today()
    if time_range == "day":
        d = today - timedelta(days=1)
    elif time_range == "week":
        d = today - timedelta(weeks=1)
    elif time_range == "month":
        d = today - timedelta(days=30)
    else:  # year
        d = today - timedelta(days=365)
    return d.strftime("%Y-%m-%d")


TOOLS = [
    Tool(
        name="web_search",
        description="Search the web and return titles, URLs, and snippets. Use this for factual lookups, finding sources, or discovering starting points for research.",
        parameters={
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "The search query"},
                "count": {"type": "integer", "description": "Number of results (default 5)"},
                "recency": {
                    "type": "string",
                    "enum": ["day", "week", "month", "year"],
                    "description": "Limit results to this time window. Use for current events, recent releases, or any query where freshness matters.",
                },
            },
            "required": ["query"],
        },
        handler=_web_search,
        category="search",
    ),
]
