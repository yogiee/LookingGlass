from ..base import Tool, ok

# `think` is a private scratchpad. It doesn't touch the outside world — it just
# echoes the model's reasoning back so it stays in the conversation context.
# The Swift UI renders it as a collapsed "thinking" card rather than as output.


async def _think(args: dict) -> dict:
    thought = args.get("thought", "")
    return ok(thought)


TOOLS = [
    Tool(
        name="think",
        description="A private space to reason through a problem step by step before answering. Use this to plan, check assumptions, or work through multi-step logic. The content is not shown to the user as a normal reply.",
        parameters={
            "type": "object",
            "properties": {
                "thought": {"type": "string", "description": "Your reasoning, written out"},
            },
            "required": ["thought"],
        },
        handler=_think,
        category="reasoning",
    ),
]
