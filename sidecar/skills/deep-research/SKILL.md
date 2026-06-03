---
name: deep-research
description: Multi-source research on a topic — search several angles, read the best sources, synthesize a cited report, save it.
when_to_use: The user asks to "research", "dig into", "look into", or "do a deep dive" on a topic (not a quick one-off lookup).
allowed_tools: [web_search, http_request, file_write, recall_memory]
---

# Deep Research

When the user wants depth, not a single answer:

1. **Frame it.** Restate the question in one line. List 3–5 sub-questions or angles
   worth covering. If the topic is ambiguous, ask one clarifying question first.
2. **Search broadly.** Run `web_search` on each angle (different phrasings, not the
   same query reworded). Collect the strongest 2–3 results per angle.
3. **Read the sources.** Use `http_request` to pull full content for the best
   results. Skim for substance; skip SEO filler and listicles.
4. **Extract.** For each source, note the key facts, figures, and direct quotes —
   and keep the URL next to each so claims stay traceable.
5. **Synthesize.** Write a structured report: short summary up top, then findings by
   theme. Cite sources inline. Call out where sources *disagree* rather than
   averaging them away.
6. **Save it.** `file_write` the report to `research/<topic-slug>.md` in the working
   directory. End with 2–3 follow-up threads worth pulling next.

Be honest about gaps: if the evidence is thin or one-sided, say so. A short report
that's accurate beats a long one that's padded.
