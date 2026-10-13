"""Cut already-speakable text into the pieces Qwen3-TTS renders one at a time.

The Swift side has already reduced markdown to the spoken layer (`SpokenLayer`), so this only has to
decide where to cut. Two reasons to cut at all:

- **Length.** One generation is capped at 4096 codec frames (12 Hz → ~340 s), and cloning quality drifts
  on very long targets. Reports are routinely longer than that.
- **Boundaries.** Cutting at paragraph and sentence ends keeps each piece a complete thought, so the
  model's natural sentence-final pause lands where a reader would pause anyway.

Piece size does NOT govern time-to-first-audio: streaming yields the first `streaming_interval` of
sound after a handful of codec frames whatever the target's length, and a longer target adds only
milliseconds of prompt processing. So there is no "short first piece" rule — it would only split a line
like "No." away from the context that gives it its delivery.

Nothing is ever dropped: the pieces concatenate back to the input's words.
"""
from __future__ import annotations

import re

# Target size for a piece. Long enough to carry prosody across a couple of sentences, short enough to
# keep cloning stable.
MAX_CHARS = 360

# A sentence ends at . ! ? or … followed by whitespace and something that starts a sentence. Requiring
# the next token to look like a sentence start keeps decimals ("3.5") and most lowercase-continued
# abbreviations ("e.g. the") in one piece. A false split costs only a chunk boundary, never words.
_SENTENCE_END = re.compile(r"(?<=[.!?…])[\"'”’)]*\s+(?=[\"'“‘(]?[A-Z0-9])")


def _sentences(paragraph: str) -> list[str]:
    return [s.strip() for s in _SENTENCE_END.split(paragraph) if s.strip()]


def _hard_split(sentence: str, limit: int) -> list[str]:
    """Last resort for a single sentence longer than the limit: cut at clause punctuation, then spaces."""
    if len(sentence) <= limit:
        return [sentence]
    out, rest = [], sentence
    while len(rest) > limit:
        window = rest[:limit]
        cut = max(window.rfind(", "), window.rfind("; "), window.rfind(": "), window.rfind(" — "))
        if cut < limit // 3:
            cut = window.rfind(" ")
        if cut <= 0:
            cut = limit
        out.append(rest[: cut + 1].strip())
        rest = rest[cut + 1:].strip()
    if rest:
        out.append(rest)
    return out


def chunk(text: str) -> list[str]:
    """Split text into synthesis pieces: one per paragraph, long paragraphs packed sentence by sentence."""
    pieces: list[str] = []
    for paragraph in (p.strip() for p in re.split(r"\n\s*\n|\n", text)):
        if not paragraph:
            continue
        buffer = ""
        for sentence in _sentences(paragraph):
            for part in _hard_split(sentence, MAX_CHARS):
                if buffer and len(buffer) + 1 + len(part) > MAX_CHARS:
                    pieces.append(buffer)
                    buffer = ""
                buffer = f"{buffer} {part}".strip()
        if buffer:
            pieces.append(buffer)
    return pieces


_KANA = re.compile(r"[぀-ヿ]")
_HANGUL = re.compile(r"[가-힯]")
_CJK = re.compile(r"[一-鿿]")


def language_for(piece: str) -> str:
    """Qwen3-TTS language hint for one piece. English unless the script says otherwise — the Japanese
    practice direction means Alice will sometimes read kana aloud."""
    if _KANA.search(piece):
        return "japanese"
    if _HANGUL.search(piece):
        return "korean"
    if _CJK.search(piece):
        return "chinese"
    return "english"
