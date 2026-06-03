"""use_skill — load a skill's full instructions on demand (progressive disclosure).

The skills *index* (names + when-to-use) is injected into the system prompt by the
agent loop; this tool returns one skill's full body so Alice can follow it. Mirrors
recall_memory: the prompt carries the index, the tool fetches the detail.
"""
from ..base import Tool, ok, err
from skill_loader import all_skills, get_skill   # sidecar root is on sys.path


def _available() -> str:
    names = ", ".join(s.name for s in all_skills())
    return names or "(no skills installed)"


async def _use_skill(args: dict) -> dict:
    name = (args.get("name") or "").strip()
    if not name:
        return err(f"Missing 'name'. Available skills: {_available()}")
    skill = get_skill(name)
    if skill is None:
        return err(f"No skill named '{name}'. Available skills: {_available()}")
    header = f"# Skill: {skill.name}\n"
    if skill.allowed_tools:
        # Guidance only — NOT enforced yet (enforcement is the future 'profiles' work).
        header += f"_Recommended tools: {', '.join(skill.allowed_tools)}._\n\n"
    return ok(header + skill.body)


TOOLS = [
    Tool(
        name="use_skill",
        description=(
            "Load the full step-by-step playbook for one of your skills before doing "
            "that kind of task. The skills index in your system prompt lists each "
            "skill's name and when to use it; call this with the skill's name to read "
            "its detailed instructions, then follow them using your other tools."
        ),
        parameters={
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Skill name from the skills index, e.g. 'deep-research'",
                },
            },
            "required": ["name"],
        },
        handler=_use_skill,
        category="skills",
    ),
]
