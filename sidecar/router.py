"""Request-mode classifier for model routing (Step 5).

Examines the last user message and returns a routing mode:
  "research"  — multi-source research, deep dives, analysis
  "coding"    — code generation, debugging, refactoring
  "default"   — general chat, Q&A, everything else

The mode maps to a key in `[models]` (project.toml or config.toml), so the
right model is loaded before inference starts. Pure keyword matching — no LLM
call, zero latency. A future v2 can replace this with the router model
(qwen3.5:2b-mlx) for nuance; the interface stays the same.
"""
import re

_RESEARCH = re.compile(
    r"\b(research|investigate|deep.dive|dig.into|look.into|analyse|analyze|"
    r"summarize|summarise|survey|study|explore|literature|background|overview|"
    r"find.out.about|what.is.the.latest|what.are.the.latest)\b",
    re.IGNORECASE,
)

_CODING = re.compile(
    r"\b(code|function|class|method|bug|fix(?:ing)?|error|exception|debug|"
    r"refactor|implement|script|syntax|compile|unit.?test|pytest|algorithm|"
    r"programming|python|swift|javascript|typescript|sql|endpoint|api|"
    r"regex|dockerfile|yaml|json.schema)\b",
    re.IGNORECASE,
)

# Tool-need detection (small-specialist fleet, 2026-06-21). The chat default (ZINI) is
# completion-only — it can't call tools. So a turn that clearly needs a live fact or a
# file/web action must route to the tool-capable lane instead of fabricating on ZINI.
# Maps to "coding" (= the tools lane, gemma4:12b-mlx in the fleet; gemma4:12b in the
# stable lock — both tool-capable, so this is benign under either config). Coarse by
# design: turns that dodge these keywords and still need a tool can leak to ZINI — the
# known structural cost of a tool-less chat default (full fix = Option B silent-hands).
_TOOL_NEED = re.compile(
    r"\b(search|look.?up|google|web|browse|fetch|download|url|https?|"
    r"current(?:ly)?|latest|today|tonight|right.now|recent|news|headline|"
    r"weather|forecast|temperature|price|cost|stock|score|exchange.rate|"
    r"who.won|when.(?:is|does|did)|read.the.file|write.(?:a|the).file|save.to|list.files)\b",
    re.IGNORECASE,
)


# ── Deterministic image-generation routing (2026-07-04) ──────────────────────────────
# A clear "make me an image" turn is handled by executing the image tool DIRECTLY — no small
# model gets to decide. The intent is recognizable, and the message IS the prompt. This pulls
# the most common + most RAM-heavy tool off the weak silent-hands path, where a 3B hands model
# both mis-decided (0 tool calls) and hallucinated a bad model= arg. Tuned for PRECISION: a
# miss just falls through to normal routing, but a false-positive wastes a ~2-min generation —
# so we require an imperative create-verb + an image noun + a subject marker, and reject
# questions. See plan_hands_model_reliability / feature_silent_hands_butler.
_IMG_VERB = (
    r"(?:generate|create|make|draw|render|paint|design|produce|sketch|illustrate|"
    r"give me|show me|get me|whip up|cook up|conjure)"
)
_IMG_NOUN = (
    r"(?:images?|pictures?|photos?|photographs?|artworks?|art|illustrations?|drawings?|"
    r"paintings?|renders?|renderings?|logos?|posters?|wallpapers?|portraits?|graphics?|"
    r"icons?|stickers?|avatars?|mockups?|banners?|sketches?|scenes?)"
)
# Subject marker after the noun ("… image OF a fox") — the discriminator that keeps
# "make sure the image loads" / "generate a report about images" from matching.
_IMG_SUBJECT = r"(?:of|showing|depicting|with|that (?:says|shows|depicts)|featuring|for|:|,|-|—)"
_IMAGE_REQ = re.compile(
    rf"\b{_IMG_VERB}\s+(?:me\s+)?(?:an?|some|a few|a couple of|the|another|new|\d+)?\s*"
    rf"(?:\w+\s+){{0,2}}?{_IMG_NOUN}\s+{_IMG_SUBJECT}\b",
    re.IGNORECASE,
)
# Reject questions/explanations up front ("how do I generate an image of …").
_IMAGE_Q = re.compile(
    r"^\s*(?:how|what|whats|what's|why|which|who|whom|whose|when|where|is|are|do|does|"
    r"did|should|could you (?:explain|tell)|can you (?:explain|tell|describe)|"
    r"tell me about|explain|describe how)\b",
    re.IGNORECASE,
)
# mode="design" → text-in-image / logos / UI / posters; else "photo" (see OllamaMCP local_image).
_IMG_DESIGN = re.compile(
    r"\b(logos?|posters?|text|signs?|signage|banners?|ui|mockups?|interfaces?|diagrams?|"
    r"icons?|illustrations?|stickers?|comics?|memes?|infographics?|flyers?|cards?|covers?|"
    r"typography|wordmarks?|emblems?|labels?|that says|with the (?:text|words|caption))\b",
    re.IGNORECASE,
)


def _last_user_text(messages: list[dict]) -> str:
    for msg in reversed(messages):
        if msg.get("role") == "user":
            return (msg.get("content") or "").strip()
    return ""


def detect_image_request(messages: list[dict]) -> dict | None:
    """If the last user turn is a clear imperative image-generation request, return
    {"prompt": <subject>, "mode": "photo"|"design"}; else None.

    Deliberately high-precision: a miss falls through to normal routing (worst case: the
    weak hands path, i.e. today's behavior), but a false-positive burns a ~2-min generation.
    """
    text = _last_user_text(messages)
    if not text or _IMAGE_Q.match(text):
        return None
    m = _IMAGE_REQ.search(text)
    if not m:
        return None
    # Prompt = the subject after the "…create an image of|" match; fall back to the full
    # message (image models tolerate an instruction-y prefix fine).
    prompt = text[m.end():].strip().strip(".!,-— ") or text
    mode = "design" if _IMG_DESIGN.search(text) else "photo"
    return {"prompt": prompt, "mode": mode}


def classify_mode(messages: list[dict]) -> str:
    """Return the routing mode for this conversation turn."""
    text = _last_user_text(messages)
    if not text:
        return "default"
    # Research checked first — "research the best algorithm" → research model,
    # not coding, which is the right call (depth over raw code generation).
    if _RESEARCH.search(text):
        return "research"
    if _CODING.search(text):
        return "coding"
    # Tool-need → the tools lane, so a tool-less chat default doesn't get the turn.
    if _TOOL_NEED.search(text):
        return "coding"
    return "default"
