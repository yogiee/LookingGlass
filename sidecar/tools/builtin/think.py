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
        description="A scratchpad to reason through a problem step by step. Call think FIRST when a question needs careful planning. After think completes, ALWAYS write your actual answer to the user as regular text. Never end a turn with only a think call.",
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
