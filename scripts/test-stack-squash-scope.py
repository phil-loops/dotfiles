#!/usr/bin/env python3
"""test-stack-squash-scope.py — stack-squash's subject scope is the Linear ticket or nothing.

Loads force_scope (and the regex it uses) out of scripts/stack-squash without running the script,
then checks it pins a ticket, strips any scope when there is no ticket (2026-11-17: a ticketless
forest got `test(goal-flip-converter):`), and recovers a dropped prefix from the squashed commits.
"""
import ast
import os
import re
import sys

src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "stack-squash")).read()
tree = ast.parse(src)
wanted = [n for n in tree.body
          if (isinstance(n, ast.FunctionDef) and n.name == "force_scope")
          or (isinstance(n, ast.Assign) and any(getattr(t, "id", "") == "_SUBJECT_RE" for t in n.targets))]
module = ast.Module(body=wanted, type_ignores=[])

failures = 0


def check(name, scope, commits, msg, want):
    global failures
    env = {"re": re, "scope": scope, "commits": commits}
    exec(compile(module, "stack-squash", "exec"), env)
    got = env["force_scope"](msg)
    if got == want:
        print(f"PASS  {name}")
    else:
        failures += 1
        print(f"FAIL  {name}: want {want!r} got {got!r}")


check("a ticket replaces any scope", "loo-123", [], "feat(goals): add flips", "feat(loo-123): add flips")
check("no ticket strips the forest name", "", [], "test(goal-flip-converter): check readers", "test: check readers")
check("no ticket strips a code-area scope", "", [], "fix(api)!: drop field", "fix!: drop field")
check("no ticket leaves a bare subject alone", "", [], "chore: tidy", "chore: tidy")
check("a dropped prefix is recovered from the commits, unscoped", "",
      ["abc123 feat: add a thing", "def456 more"], "add a thing", "feat: add a thing")
check("a dropped prefix is recovered with the ticket", "loo-9",
      ["abc123 fix(x): mend"], "mend it", "fix(loo-9): mend it")
check("the body is kept", "", [], "feat(x): a\n\nwhy it matters", "feat: a\n\nwhy it matters")

print(f"{7 - failures} passed, {failures} failed")
sys.exit(1 if failures else 0)
