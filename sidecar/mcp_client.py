"""Persistent MCP server connections for the sidecar tool router.

Each McpConnection spawns a server process and keeps it alive via a background
asyncio task that holds the stdio_client + ClientSession context managers open.
Tool calls are dispatched through an asyncio.Queue and resolved via Futures —
no per-call spawn overhead.

Usage (in main.py lifespan):
    conn = McpConnection("memoryCentral", "/opt/homebrew/bin/node",
                         ["/path/to/server/index.js"])
    await conn.start()                  # initialise + populate .tools
    # ... conn.tools is now a list[mcp.types.Tool]
    result = await conn.call_tool("search_memories", {"query": "auth"})
    await conn.stop()                   # clean shutdown on sidecar exit
"""
import asyncio
import os

from mcp import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client


class McpConnection:
    """Persistent stdio connection to one MCP server."""

    def __init__(
        self,
        name: str,
        command: str,
        args: list[str],
        env: dict[str, str] | None = None,
    ) -> None:
        self.name = name
        self._command = command
        self._args = args
        self._extra_env = env or {}

        self._tools: list = []
        self._initialized = asyncio.Event()
        self._init_error: Exception | None = None
        self._queue: asyncio.Queue = asyncio.Queue()
        self._task: asyncio.Task | None = None

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def start(self, timeout: float = 30.0) -> None:
        """Spawn the server and wait for it to finish initializing."""
        self._task = asyncio.create_task(self._run(), name=f"mcp:{self.name}")
        await asyncio.wait_for(self._initialized.wait(), timeout=timeout)
        if self._init_error:
            raise self._init_error

    async def call_tool(self, tool_name: str, arguments: dict):
        """Call a tool on this server; returns the mcp CallToolResult."""
        if self._task is None or self._task.done():
            raise RuntimeError(f"MCP server '{self.name}' is not running.")
        loop = asyncio.get_event_loop()
        fut: asyncio.Future = loop.create_future()
        await self._queue.put((tool_name, arguments, fut))
        return await fut

    async def stop(self) -> None:
        """Cancel the background task and wait for cleanup."""
        if self._task and not self._task.done():
            self._task.cancel()
            try:
                await self._task
            except (asyncio.CancelledError, Exception):
                pass

    @property
    def tools(self) -> list:
        return self._tools

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    async def _run(self) -> None:
        merged_env = {**os.environ, **self._extra_env} if self._extra_env else None
        params = StdioServerParameters(
            command=self._command,
            args=self._args,
            env=merged_env,
        )
        try:
            async with stdio_client(params) as (read, write):
                async with ClientSession(read, write) as session:
                    await session.initialize()
                    result = await session.list_tools()
                    self._tools = result.tools
                    self._initialized.set()

                    while True:
                        tool_name, arguments, fut = await self._queue.get()
                        try:
                            r = await session.call_tool(tool_name, arguments)
                            if not fut.done():
                                fut.set_result(r)
                        except Exception as exc:
                            if not fut.done():
                                fut.set_exception(exc)

        except asyncio.CancelledError:
            raise  # let the task finish cleanly
        except Exception as exc:
            self._init_error = exc
            self._initialized.set()  # unblock start() so it can raise
