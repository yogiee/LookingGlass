import json
import tomllib
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from sse_starlette.sse import EventSourceResponse

from agent import AgentConfig, chat_stream
from tools.builtin.memory import save_memory_entry
from tools.context import reset_project_dir, set_project_dir
from tools.registry import ToolRegistry

BASE_DIR = Path(__file__).parent


def load_config() -> dict:
    with open(BASE_DIR / "config.toml", "rb") as f:
        return tomllib.load(f)


config = load_config()

system_prompt_path = BASE_DIR / config["agent"]["system_prompt_path"]
system_prompt = system_prompt_path.read_text()

agent_config = AgentConfig(
    ollama_host=config["model"]["ollama_host"],
    default_model=config["model"]["default"],
    system_prompt=system_prompt,
    think=config["model"].get("think", False),
    max_turns=config["agent"].get("max_turns", 10),
    keep_alive=config["model"].get("keep_alive", "5m"),
    num_ctx=config["model"].get("num_ctx", 16384),
    models=config.get("models", {}),
)

registry = ToolRegistry()
registry.discover()

PORT = config["server"]["port"]
HOST = config["server"].get("host", "127.0.0.1")


@asynccontextmanager
async def lifespan(app: FastAPI):
    print(f"[sidecar] Starting on {HOST}:{PORT}")
    print(f"[sidecar] Model: {agent_config.default_model}")
    print(f"[sidecar] Ollama: {agent_config.ollama_host}")
    print(f"[sidecar] Tools: {', '.join(registry.names())}")
    yield
    print("[sidecar] Shutting down")


app = FastAPI(title="LookingGlass Sidecar", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


class MessageIn(BaseModel):
    role: str
    content: str


class ChatRequest(BaseModel):
    messages: list[MessageIn]
    model: str | None = None
    ollama_host: str | None = None
    enabled_tools: list[str] | None = None
    system_prompt: str | None = None
    project_dir: str | None = None     # absolute project folder, or None for independent chats
    working_dir: str | None = None     # tool output scope; sidecar derives it when absent


def _host_for(override: str | None) -> str:
    return override or agent_config.ollama_host


@app.get("/health")
async def health(ollama_host: str | None = None):
    host = _host_for(ollama_host)
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(f"{host}/api/tags", timeout=3.0)
            r.raise_for_status()
        return {"status": "ok", "model": agent_config.default_model, "tools": len(registry.names())}
    except Exception:
        return {
            "status": "degraded",
            "model": agent_config.default_model,
            "tools": len(registry.names()),
            "error": "Ollama not reachable",
        }


@app.get("/models")
async def models(ollama_host: str | None = None):
    host = _host_for(ollama_host)
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(f"{host}/api/tags", timeout=5.0)
            r.raise_for_status()
            data = r.json()
            return {"models": [m["name"] for m in data.get("models", [])]}
    except Exception as e:
        return {"models": [], "error": str(e)}


@app.get("/tools")
async def tools():
    return {"tools": registry.describe_all()}


class MemorySaveRequest(BaseModel):
    title: str
    content: str
    description: str | None = None
    type: str | None = None
    project_dir: str | None = None     # which project's memory-bank to write into


@app.post("/memory/save")
async def memory_save(request: MemorySaveRequest):
    """Deterministic, no-model memory save — backs the per-message "Save to
    memory" button. Same write path as the save_memory tool; we just set the
    project context explicitly instead of inheriting it from a chat request."""
    token = set_project_dir(Path(request.project_dir).expanduser() if request.project_dir else None)
    try:
        return save_memory_entry(
            title=request.title,
            content=request.content,
            description=request.description,
            mem_type=request.type or "project",
        )
    finally:
        reset_project_dir(token)


@app.post("/chat")
async def chat(request: ChatRequest):
    # Model is resolved inside chat_stream (explicit pick → project default →
    # global default), so the project's [models].default can apply.
    messages = [{"role": m.role, "content": m.content} for m in request.messages]

    async def event_gen():
        try:
            async for event in chat_stream(
                messages,
                request.model,
                agent_config,
                registry,
                enabled_tools=request.enabled_tools,
                ollama_host=request.ollama_host,
                system_prompt=request.system_prompt,
                project_dir=request.project_dir,
                working_dir=request.working_dir,
            ):
                yield {"data": json.dumps(event)}
        except Exception as e:
            yield {"data": json.dumps({"type": "error", "message": str(e)})}

    return EventSourceResponse(event_gen())


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=HOST, port=PORT, log_level="info")
