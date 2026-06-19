import asyncio
import json
import shutil
import tomllib
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from sse_starlette.sse import EventSourceResponse

from agent import AgentConfig, chat_stream
from tools.builtin.memory import save_memory_entry
from tools.context import reset_project_dir, set_project_dir
from tools.registry import ToolRegistry

BASE_DIR = Path(__file__).parent
MCP_USER_FILE = BASE_DIR / "mcp_user_servers.json"


def load_config() -> dict:
    with open(BASE_DIR / "config.toml", "rb") as f:
        return tomllib.load(f)


def load_model_registry() -> dict:
    """Our hand-maintained OPINION of known chat models (role/tier/speed/note),
    keyed by Ollama tag. Pure metadata — installed/capable stay live from Ollama.
    Re-read at startup; missing file is fine (everything just shows as 'untested')."""
    path = BASE_DIR / "models.toml"
    if not path.is_file():
        return {}
    try:
        with open(path, "rb") as f:
            return tomllib.load(f).get("models", {})
    except Exception as e:
        print(f"[sidecar] models.toml load failed: {e}")
        return {}


def load_user_mcp_servers() -> list[dict]:
    if not MCP_USER_FILE.is_file():
        return []
    try:
        return json.loads(MCP_USER_FILE.read_text(encoding="utf-8"))
    except Exception:
        return []


def save_user_mcp_servers(servers: list[dict]) -> None:
    MCP_USER_FILE.write_text(json.dumps(servers, indent=2), encoding="utf-8")


config = load_config()
MODEL_REGISTRY = load_model_registry()

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

    config_servers = config.get("mcp", {}).get("servers", [])
    user_servers = load_user_mcp_servers()
    config_names = {s.get("name") for s in config_servers}
    all_mcp = config_servers + [s for s in user_servers if s.get("name") not in config_names]
    if all_mcp:
        await registry.discover_mcp(all_mcp)
        print(f"[sidecar] All tools: {', '.join(registry.names())}")

    yield

    print("[sidecar] Shutting down")
    await registry.shutdown()


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
    project_dir: str | None = None          # absolute project folder, or None for independent chats
    working_dir: str | None = None          # tool output scope; sidecar derives it when absent
    user_name: str | None = None            # prepended to system prompt as "The user's name is X."
    mcp_hints_enabled: dict[str, bool] | None = None  # per-server MCP prompt injection toggle
    research_mode: bool = False               # forces deep-research skill + research model
    specialist_mode: bool = False             # per-turn "consult the big model" — routes to [models].specialist, overrides pick


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
            names = [m["name"] for m in r.json().get("models", [])]

            # The picker is for chatting, so show only chat-capable models. Ollama
            # tags each model's capabilities via /api/show; embedding-only and
            # image-gen models lack "completion" and would error if chatted with, so
            # they're hidden. Probes run concurrently; fail-open on a probe error so a
            # transient hiccup never hides a usable model.
            async def is_chat(name: str) -> bool:
                try:
                    resp = await client.post(f"{host}/api/show", json={"model": name}, timeout=5.0)
                    caps = resp.json().get("capabilities") or []
                    return "completion" in caps if caps else True
                except Exception:
                    return True
            flags = await asyncio.gather(*(is_chat(n) for n in names))

            # Live (installed ∩ chat-capable) LEFT JOIN our opinion (models.toml).
            # Installed+capable models absent from the registry still show, tagged
            # "untested" — honest, not hidden. Registry is opinion only.
            out: list[dict] = []
            for name, ok in zip(names, flags):
                if not ok:
                    continue
                opinion = MODEL_REGISTRY.get(name)
                entry: dict = {"name": name, "capable": True}
                if opinion:
                    entry.update({
                        "role": opinion.get("role"),
                        "tier": opinion.get("tier"),
                        "tokps": opinion.get("tokps"),
                        "ram_gb": opinion.get("ram_gb"),
                        "location": opinion.get("location", "local"),
                        "recommended": opinion.get("recommended", False),
                        "note": opinion.get("note"),
                        "untested": False,
                    })
                else:
                    # Name carries the only live cloud signal when there's no opinion.
                    entry.update({
                        "location": "cloud" if "cloud" in name else "local",
                        "recommended": False,
                        "untested": True,
                    })
                out.append(entry)
            return {"models": out}
    except Exception as e:
        return {"models": [], "error": str(e)}


@app.get("/tools")
async def tools():
    return {"tools": registry.describe_all()}


# MARK: - Skills

@app.get("/skills")
async def list_skills():
    from skill_loader import all_skills
    skills = all_skills()
    return {"skills": [
        {
            "name": s.name,
            "description": s.description,
            "when_to_use": s.when_to_use,
            "folder": s.path.parent.name,
        }
        for s in skills
    ]}


class SkillImportRequest(BaseModel):
    name: str       # folder name (slugified)
    content: str    # full SKILL.md text


@app.post("/skills/import")
async def import_skill(req: SkillImportRequest):
    from skill_loader import SKILLS_DIR
    safe_name = req.name.strip().replace("/", "_").replace("..", "_") or "unnamed"
    skill_dir = SKILLS_DIR / safe_name
    skill_dir.mkdir(parents=True, exist_ok=True)
    (skill_dir / "SKILL.md").write_text(req.content, encoding="utf-8")
    return {"success": True, "name": safe_name}


@app.delete("/skills/{folder_name}")
async def delete_skill(folder_name: str):
    from skill_loader import SKILLS_DIR
    skill_dir = SKILLS_DIR / folder_name
    if not skill_dir.is_dir():
        raise HTTPException(status_code=404, detail="Skill not found")
    shutil.rmtree(skill_dir)
    return {"success": True}


# MARK: - MCP Servers

@app.get("/mcp/status")
async def mcp_status():
    return {"servers": registry.mcp_status()}


@app.get("/mcp/servers")
async def mcp_servers():
    config_servers = config.get("mcp", {}).get("servers", [])
    user_servers = load_user_mcp_servers()
    config_names = {s.get("name") for s in config_servers}
    prompts_index = registry.mcp_prompts_index()
    result = [{"source": "config", "prompts": prompts_index.get(s.get("name"), []), **s}
              for s in config_servers]
    for s in user_servers:
        if s.get("name") not in config_names:
            result.append({"source": "user", "prompts": prompts_index.get(s.get("name"), []), **s})
    return {"servers": result}


class MCPServerAdd(BaseModel):
    name: str
    command: str
    args: list[str] = []
    env: dict[str, str] = {}


@app.post("/mcp/servers")
async def add_mcp_server(server: MCPServerAdd):
    servers = load_user_mcp_servers()
    servers = [s for s in servers if s.get("name") != server.name]
    servers.append({
        "name": server.name,
        "command": server.command,
        "args": server.args,
        "env": server.env,
    })
    save_user_mcp_servers(servers)
    return {"success": True, "restart_required": True}


@app.delete("/mcp/servers/{name}")
async def delete_mcp_server(name: str):
    servers = load_user_mcp_servers()
    before = len(servers)
    servers = [s for s in servers if s.get("name") != name]
    if len(servers) == before:
        raise HTTPException(status_code=404, detail="Server not found in user config")
    save_user_mcp_servers(servers)
    return {"success": True, "restart_required": True}


# MARK: - Memory

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


# MARK: - Chat

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
                user_name=request.user_name,
                mcp_hints_enabled=request.mcp_hints_enabled,
                research_mode=request.research_mode,
                specialist_mode=request.specialist_mode,
            ):
                yield {"data": json.dumps(event)}
        except Exception as e:
            yield {"data": json.dumps({"type": "error", "message": str(e)})}

    return EventSourceResponse(event_gen())


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=HOST, port=PORT, log_level="info")
