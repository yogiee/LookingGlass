<div align="center">

<img src="docs/icon.png" width="128" alt="Looking Glass icon">

# Looking Glass

**A local AI research companion for macOS.**
Native SwiftUI on the surface, a Python agent underneath, and everything runs on your own machine.

[![Latest release](https://img.shields.io/github/v/release/yogiee/LookingGlass)](https://github.com/yogiee/LookingGlass/releases/latest)
![Platform](https://img.shields.io/badge/macOS-14%2B-blue)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-black)

</div>

---

Looking Glass is a chat app built around **Alice** — a research companion who's direct, curious, and actually in it with you, not a cheerful service desk. It talks to a local [Ollama](https://ollama.com) model, runs tools on your behalf, and keeps your conversations on disk where they belong. No cloud, no accounts, no telemetry.

It's a two-process app: a native SwiftUI window owns the experience, and a local Python sidecar owns the intelligence (the agent loop, tool execution, and inference calls). They talk over `localhost` via HTTP + server-sent events.

## Features

- **Streaming chat** with a frosted-glass UI — rail + collapsible sidebar, light/dark, optional Wonderland theme
- **Conversation history** that persists across launches (SQLite + full-text search), with **folder-bound Projects** alongside independent chats — rename, delete, search, organize
- **Built-in tools** — file read/write, shell, web search, HTTP, calculator, PDF extract, and a thinking scratchpad — run through a multi-turn agent loop with inline tool-call cards
- **GitHub-flavored markdown** rendering — headings, blockquotes, tables, task lists, code blocks
- **Selectable chat font** — a sans for prose paired with a matching monospace for code (SF Pro, Inter, IBM Plex Sans, Roboto)
- **Configurable** — Ollama URL, per-tool toggles, custom avatar, font size, line height, and Alice's system prompt, all in Settings
- **Auto-updates** via [Sparkle](https://sparkle-project.org)

## Requirements

- macOS 14+ on **Apple Silicon**
- [Ollama](https://ollama.com) running locally (default model `qwen3.5:9b` — pull it with `ollama pull qwen3.5:9b`)
- Homebrew Python (the app embeds its own venv but uses the Homebrew interpreter)

## Install

Download the latest `LookingGlass.dmg` from the [**Releases**](https://github.com/yogiee/LookingGlass/releases/latest) page, drag it to Applications, and launch. The app starts and health-checks its sidecar automatically; updates arrive in-app via Sparkle.

## Build from source

```bash
# Run in development (bare executable, sidecar auto-launched)
swift run

# Or build a distributable .app with an embedded sidecar venv
./scripts/build-app.sh debug      # → build/LookingGlass.app
./scripts/build-app.sh release    # → build/LookingGlass.app + signed DMG
```

The sidecar can also run on its own:

```bash
cd sidecar && pip install -r requirements.txt && python main.py
curl http://localhost:8765/health
```

## Architecture

```
SwiftUI App  ──HTTP + SSE (localhost:8765)──▶  Python Sidecar (FastAPI)
   renders                                        ├─▶ Ollama (inference)
   never runs tools                               └─▶ Tool router → builtin tools + MCP
```

Swift owns the surface — rendering, history, configuration. The sidecar owns the intelligence — the agent loop, tool routing, and prompt composition. Adding a tool needs no Swift changes: drop a module in `sidecar/tools/builtin/` and restart.

## Alice

A system prompt is prepended to every conversation — never bypassed. The repo ships a generic research-companion Alice (`sidecar/prompts/alice.md`); set your own in **Settings → Personality → System Prompt** and it's used instead, stored locally.

---

<div align="center">
<sub>A personal project, shared in the open. Built for daily use on a Mac.</sub>
</div>
