#!/usr/bin/env python3
"""srv/state.py's _owes_all: a branch owes the highest link in its chain that's off its parent's tip."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from srv import state  # noqa: E402


def b(name, parent, drifted):
    return {"name": name, "parentId": f"r:{parent}" if parent else None, "drifted": drifted}


br = {"r:a": b("a", None, False), "r:b": b("b", "a", True), "r:c": b("c", "b", False), "r:d": b("d", "c", True),
      "r:x": b("x", None, False)}
state._owes_all(br)
fails = 0
for bid, want in (("r:a", None), ("r:b", "b"), ("r:c", "b"), ("r:d", "b"), ("r:x", None)):
    ok = br[bid]["owes"] == want
    fails += 0 if ok else 1
    print(("✓ " if ok else "✗ ") + f"{bid} owes {want}" + ("" if ok else f" (got {br[bid]['owes']})"))
print("all passed" if not fails else f"{fails} failed")
sys.exit(1 if fails else 0)
