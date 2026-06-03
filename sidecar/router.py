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


def classify_mode(messages: list[dict]) -> str:
    """Return the routing mode for this conversation turn."""
    text = ""
    for msg in reversed(messages):
        if msg.get("role") == "user":
            text = msg.get("content", "")
            break
    if not text:
        return "default"
    # Research checked first — "research the best algorithm" → research model,
    # not coding, which is the right call (depth over raw code generation).
    if _RESEARCH.search(text):
        return "research"
    if _CODING.search(text):
        return "coding"
    return "default"
