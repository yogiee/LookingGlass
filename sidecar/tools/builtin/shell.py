import asyncio
import os
from pathlib import Path

from ..base import Tool, ok, err
from ..context import working_dir

DEFAULT_TIMEOUT = 30
MAX_OUTPUT = 100_000


async def _shell_exec(args: dict) -> dict:
    command = args.get("command")
    if not command:
        return err("Missing required argument: command")

    # Default cwd = the request's working dir (the project folder, or
    # ~/LookingGlass/Inbox for non-project chats), falling back to home outside a
    # chat request. An explicit cwd still wins. Invariant #5 holds — this narrows
    # the default; it never silently widens scope beyond what's requested.
    cwd = args.get("cwd")
    workdir = Path(cwd).expanduser().resolve() if cwd else (working_dir() or Path.home())
    if not workdir.is_dir():
        return err(f"Working directory does not exist: {workdir}")

    timeout = int(args.get("timeout", DEFAULT_TIMEOUT))

    try:
        proc = await asyncio.create_subprocess_shell(
            command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            cwd=str(workdir),
            env={**os.environ},
        )
    except Exception as e:
        return err(f"Failed to launch: {type(e).__name__}: {e}")

    try:
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return err(f"Command timed out after {timeout}s")

    output = stdout.decode("utf-8", errors="replace")
    if len(output) > MAX_OUTPUT:
        output = output[:MAX_OUTPUT] + f"\n\n[truncated at {MAX_OUTPUT} chars]"

    rc = proc.returncode
    header = f"$ {command}\n(cwd: {workdir}, exit: {rc})\n\n"
    if rc == 0:
        return ok(header + (output or "(no output)"))
    return err(header + (output or "(no output)"))


TOOLS = [
    Tool(
        name="shell_exec",
        description="Run a shell command and return combined stdout/stderr and the exit code. Defaults to the current project's folder (or ~/LookingGlass/Inbox for non-project chats); pass cwd to scope elsewhere.",
        parameters={
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "The shell command to run"},
                "cwd": {"type": "string", "description": "Working directory (default: home)"},
                "timeout": {"type": "integer", "description": "Timeout in seconds (default 30)"},
            },
            "required": ["command"],
        },
        handler=_shell_exec,
        category="shell",
        dangerous=True,
    ),
]
