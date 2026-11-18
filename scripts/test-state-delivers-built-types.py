#!/usr/bin/env python3
"""srv/state.py: every entity type the git domain builds reaches the snapshot — gaterun was built
by _git_entities and dropped by a merge that listed its own types (2026-11-18)."""
import ast
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from srv import state  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


built = {t: {f"r:{t}": {"id": f"r:{t}"}} for t in state.GIT_TYPES}
merged = state._merge([built], state.GIT_TYPES)
check("every declared git type survives the merge", all(merged[t] for t in state.GIT_TYPES), merged)

# the builder's own literal type keys must all be declared: read _git_entities' ents[...] writes
src = open(os.path.join(HERE, "srv", "state.py")).read()
fn = next(n for n in ast.walk(ast.parse(src)) if isinstance(n, ast.FunctionDef) and n.name == "_git_entities")
written = {n.slice.value for n in ast.walk(fn) if isinstance(n, ast.Subscript) and isinstance(n.value, ast.Name)
           and n.value.id == "ents" and isinstance(n.slice, ast.Constant) and isinstance(n.slice.value, str)}
check("every type _git_entities writes is declared in GIT_TYPES", written <= set(state.GIT_TYPES), written - set(state.GIT_TYPES))
check("…including the gates run", "gaterun" in written and "gaterun" in state.GIT_TYPES, written)

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
