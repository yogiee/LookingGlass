---
name: deep-research
description: Multi-source research on a topic — search several angles, read the best sources, synthesize a cited report, save it.
when_to_use: The user asks to "research", "dig into", "look into", or "do a deep dive" on a topic (not a quick one-off lookup).
allowed_tools: [web_search, read_page, http_request, file_write, recall_memory]
---

# Deep Research

Follow all steps without stopping. After each tool call, immediately call the next
required tool — do NOT produce a prose response mid-playbook. Only generate prose
in step 5 (the report body) and only via file_write in step 6.

1. **Frame it (internal only — no prose output).** Think through 3–5 angles or
   sub-questions worth covering. Do NOT write this out — go directly to step 2.

2. **Search broadly.** Call `web_search` on each angle immediately, one after
   another. Use different phrasings — not the same query reworded. Collect the
   strongest 2–3 URLs per angle.

3. **Read the sources.** Call `read_page` on the best URLs — it returns clean
   readable markdown. Read at least 3–5 sources. Skip SEO filler and listicles.
   Only fall back to `http_request` for APIs or non-HTML endpoints.

4. **Extract.** Note key facts, figures, and direct quotes. Keep the source URL
   next to each claim so findings stay traceable.

5. **Synthesize.** Compose a structured report: short summary up top, then findings
   by theme. Cite sources inline (`[source](url)`). Call out where sources disagree
   rather than averaging them away.

6. **Save, then hand off.** Call `file_write` with path `research/<topic-slug>.md`
   containing the full report. This step is required — the run is not complete until
   file_write succeeds.

   In the **same message** as the file_write call, write a short in-chat handoff
   (100–150 words max). Do NOT reproduce the report — the user can read it in the
   panel. Instead:
   - One line confirming you saved it (file name or topic, not full path)
   - 3–4 bullet highlights: the most interesting or surprising things you found
   - One line inviting them to review and ask for corrections, deeper dives on
     any section, or follow-up threads

   Write it as Alice — direct, a little curious, not a formal summary. You just
   did the digging; hand it over like a colleague who found something interesting.

Be honest about gaps. A short accurate report beats a padded one.
