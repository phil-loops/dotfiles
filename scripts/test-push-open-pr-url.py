#!/usr/bin/env python3
"""srv/push.py's post-push PR lookup: a first push asks nothing; a re-push the server's PR map
knows answers from the map; only an unknown re-push asks gh."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


class _State:
    @staticmethod
    def poke():
        pass


sys.modules["srv.state"] = _State
from srv import ctx  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


class R:
    def __init__(self, out=""):
        self.stdout, self.stderr, self.returncode = out, "", 0


calls = []


def run(argv, **kw):
    calls.append(argv)
    if argv[:2] == ["git", "remote"]:
        return R("git@github.com:Loops-so/loops.git")
    if argv[0] == "gh":
        return R('[{"url": "https://github.com/Loops-so/loops/pull/9"}]')
    return R("")


ctx.run = run
ctx.CWD = ctx.MAIN_WT = os.getcwd()
from srv import outbox, push  # noqa: E402

outbox._pr_map = lambda: ({"feat": {"url": "https://github.com/Loops-so/loops/pull/7", "state": "OPEN"}}, "state")

check("a first push asks nothing", push._open_pr_url("feat", first=True) == "" and calls == [], calls)
check("a re-push the map knows answers from the map", push._open_pr_url("feat") == "https://github.com/Loops-so/loops/pull/7" and calls == [], calls)
check("an unknown re-push asks gh once on origin", push._open_pr_url("other") == "https://github.com/Loops-so/loops/pull/9"
      and sum(1 for c in calls if c[0] == "gh") == 1, calls)

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
