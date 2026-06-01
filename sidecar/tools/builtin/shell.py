import asyncio
import os
from pathlib import Path

from ..base import Tool, ok, err

DEFAULT_TIMEOUT = 30
MAX_OUTPUT = 100_000


async def _shell_exec(args: dict) -> dict:
    command = args.get("command")
    if not command:
        return err("Missing required argument: command")

    # Scope to home directory by default (invariant #5). A caller may pass an
    # explicit cwd, but we don't silently widen scope beyond what's requested.
    cwd = args.get("cwd")
    workdir = Path(cwd).expanduser().resolve() if cwd else Path.home()
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
        description="Run a shell command and return combined stdout/stderr and the exit code. Defaults to the user's home directory; pass cwd to scope elsewhere.",
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
