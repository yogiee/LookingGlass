from pathlib import Path

from ..base import Tool, ok, err

MAX_CHARS = 200_000


async def _pdf_extract(args: dict) -> dict:
    path = args.get("path")
    if not path:
        return err("Missing required argument: path")
    p = Path(path).expanduser().resolve()
    if not p.exists():
        return err(f"File not found: {p}")

    try:
        from pypdf import PdfReader
    except ImportError:
        return err("pypdf is not installed. Run: pip install pypdf")

    try:
        reader = PdfReader(str(p))
    except Exception as e:
        return err(f"Could not open PDF: {type(e).__name__}: {e}")

    pages = args.get("pages")  # optional "1-5" or "3"
    page_indices = _parse_pages(pages, len(reader.pages))

    chunks = []
    for idx in page_indices:
        try:
            text = reader.pages[idx].extract_text() or ""
        except Exception:
            text = ""
        chunks.append(f"--- Page {idx + 1} ---\n{text.strip()}")

    out = "\n\n".join(chunks)
    if len(out) > MAX_CHARS:
        out = out[:MAX_CHARS] + f"\n\n[truncated at {MAX_CHARS} chars]"
    header = f"{p.name} — {len(reader.pages)} pages, extracted {len(page_indices)}\n\n"
    return ok(header + (out or "(no extractable text — PDF may be scanned images)"))


def _parse_pages(spec, total: int) -> list[int]:
    if not spec:
        return list(range(total))
    spec = str(spec).strip()
    if "-" in spec:
        try:
            a, b = spec.split("-", 1)
            start = max(1, int(a))
            end = min(total, int(b))
            return list(range(start - 1, end))
        except ValueError:
            return list(range(total))
    try:
        n = int(spec)
        if 1 <= n <= total:
            return [n - 1]
    except ValueError:
        pass
    return list(range(total))


TOOLS = [
    Tool(
        name="pdf_extract",
        description="Extract text from a PDF file. Optionally limit to a page range like '1-5' or a single page. Returns plain text per page.",
        parameters={
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Path to the PDF file"},
                "pages": {"type": "string", "description": "Optional page range, e.g. '1-5' or '3'"},
            },
            "required": ["path"],
        },
        handler=_pdf_extract,
        category="media",
    ),
]
