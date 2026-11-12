#!/usr/bin/env python3
"""srv/foreign.py's stack derivation: from one PR, up its bases to the root and down every PR based on
a node's head; a fan-out keeps both children; PRs off the stack stay out; an unknown PR is None."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from srv import foreign  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


def pr(n, head, base, author="maksim"):
    return {"number": n, "title": f"pr {n}", "headRefName": head, "baseRefName": base,
            "author": {"login": author}, "isDraft": False, "url": f"https://github.invalid/pull/{n}"}


prs = [pr(406, "footers-6", "main"), pr(407, "footers-7", "footers-6"), pr(408, "footers-8", "footers-7"),
       pr(410, "footers-10", "footers-8"), pr(409, "footers-9-alt", "footers-8"),
       pr(500, "unrelated", "main", "someone")]
s = foreign.stack_of(prs, 408)
check("the root is found by following bases up", s["root"] == 406, s["root"])
check("every descendant, depth first, children by number",
      [n["number"] for n in s["nodes"]] == [406, 407, 408, 409, 410], [n["number"] for n in s["nodes"]])
by = {n["number"]: n for n in s["nodes"]}
check("parents and depths follow the chain", by[407]["parent"] == 406 and by[410]["parent"] == 408 and by[410]["depth"] == 3 and by[406]["parent"] is None)
check("a fan-out keeps both children of one base", by[409]["parent"] == 408 and by[410]["parent"] == 408)
check("a PR off the stack stays out", 500 not in by)
check("asking from the root gives the same stack", foreign.stack_of(prs, 406)["nodes"] == s["nodes"])
check("an unknown PR is None", foreign.stack_of(prs, 999) is None)
loop = [pr(1, "a", "b"), pr(2, "b", "a")]
check("a base cycle can't spin", foreign.stack_of(loop, 1) is not None)

# a fork's PR whose head is named main: it doesn't root the main-based stack, and nothing chains on it
fork = dict(pr(600, "main", "footers-8", author="outsider"), isCrossRepository=True)
s2 = foreign.stack_of(prs + [fork], 406)
check("a fork PR named main doesn't become every stack's root", s2["root"] == 406, s2["root"])
check("…it sits in the stack it's based on, as a leaf", [n["number"] for n in s2["nodes"] if n["parent"] == 408] == [409, 410, 600], s2["nodes"])
s3 = foreign.stack_of(prs + [fork, pr(700, "other", "main")], 600)
check("…and asking from it walks up its own bases, not every main-based PR", s3["root"] == 406 and 700 not in {n["number"] for n in s3["nodes"]}, s3)

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
