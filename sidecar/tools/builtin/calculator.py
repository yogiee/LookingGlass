import ast
import math
import operator

from ..base import Tool, ok, err

# Safe arithmetic evaluator — no eval(), only a whitelisted AST.

_BIN_OPS = {
    ast.Add: operator.add,
    ast.Sub: operator.sub,
    ast.Mult: operator.mul,
    ast.Div: operator.truediv,
    ast.FloorDiv: operator.floordiv,
    ast.Mod: operator.mod,
    ast.Pow: operator.pow,
}
_UNARY_OPS = {
    ast.UAdd: operator.pos,
    ast.USub: operator.neg,
}
_FUNCS = {
    "sqrt": math.sqrt, "sin": math.sin, "cos": math.cos, "tan": math.tan,
    "asin": math.asin, "acos": math.acos, "atan": math.atan, "atan2": math.atan2,
    "log": math.log, "log2": math.log2, "log10": math.log10, "exp": math.exp,
    "floor": math.floor, "ceil": math.ceil, "abs": abs, "round": round,
    "factorial": math.factorial, "gcd": math.gcd, "hypot": math.hypot,
    "degrees": math.degrees, "radians": math.radians, "pow": pow,
}
_CONSTS = {"pi": math.pi, "e": math.e, "tau": math.tau, "inf": math.inf}


def _eval(node):
    if isinstance(node, ast.Constant):
        if isinstance(node.value, (int, float)):
            return node.value
        raise ValueError("only numeric constants allowed")
    if isinstance(node, ast.BinOp):
        op = _BIN_OPS.get(type(node.op))
        if op is None:
            raise ValueError("operator not allowed")
        return op(_eval(node.left), _eval(node.right))
    if isinstance(node, ast.UnaryOp):
        op = _UNARY_OPS.get(type(node.op))
        if op is None:
            raise ValueError("unary operator not allowed")
        return op(_eval(node.operand))
    if isinstance(node, ast.Name):
        if node.id in _CONSTS:
            return _CONSTS[node.id]
        raise ValueError(f"unknown name: {node.id}")
    if isinstance(node, ast.Call):
        if not isinstance(node.func, ast.Name) or node.func.id not in _FUNCS:
            raise ValueError("function not allowed")
        fn = _FUNCS[node.func.id]
        a = [_eval(x) for x in node.args]
        return fn(*a)
    raise ValueError("unsupported expression")


async def _calculator(args: dict) -> dict:
    expr = args.get("expression")
    if not expr:
        return err("Missing required argument: expression")
    try:
        tree = ast.parse(expr, mode="eval")
        result = _eval(tree.body)
        return ok(f"{expr} = {result}")
    except ZeroDivisionError:
        return err("Division by zero")
    except Exception as e:
        return err(f"Could not evaluate: {e}")


TOOLS = [
    Tool(
        name="calculator",
        description="Evaluate a mathematical expression. Supports + - * / // % **, and functions like sqrt, sin, cos, log, exp, factorial, plus constants pi and e.",
        parameters={
            "type": "object",
            "properties": {
                "expression": {"type": "string", "description": "The math expression, e.g. 'sqrt(2) * 10' or '2**16'"},
            },
            "required": ["expression"],
        },
        handler=_calculator,
        category="math",
    ),
]
