#!/usr/bin/env python3
"""srv/viewed.py against a throwaway git repo: viewed and flagged marks, unmarking across branches,
version-1 migration, marks following `git branch -m`, and a deleted branch's marks pruned."""
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from srv import ctx, viewed  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


def git(*args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=True).stdout.strip()


class Req:
    def __init__(self):
        self.status, self.body = None, None

    def _send(self, status, body):
        self.status, self.body = status, json.loads(body)


def post(body):
    r = Req()
    viewed.post(r, json.dumps(body))
    return r


def marks():
    return viewed.entities("loops")["viewed"]


class _State:
    @staticmethod
    def poke():
        pass


sys.modules["srv.state"] = _State
import srv  # noqa: E402
srv.state = _State

repo = tempfile.mkdtemp(prefix="viewed-test-")
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)
git("commit", "-q", "--allow-empty", "-m", "root")
for b in ("alpha", "beta", "gone"):
    git("branch", b)
ctx.CWD = repo
ctx.run = lambda argv, **kw: subprocess.run(argv, capture_output=True, text=True)
store = os.path.join(repo, ".git", "stack-viewed.json")

# version 1 on disk: read by branch name, migrated on the next write, dead names dropped
with open(store, "w") as f:
    json.dump({"alpha": {"aaa": 1}, "nobranch": {"zzz": 1}}, f)
check("version 1 reads as viewed by branch", marks().get("loops:alpha", {}).get("keys") == ["aaa"], marks())
r = post({"branch": "alpha", "keys": ["bbb"], "state": "viewed"})
data = json.load(open(store))
check("a write migrates to version 2", r.status == 200 and data.get("version") == 2, data)
check("…keeping alpha's old marks", sorted(marks()["loops:alpha"]["keys"]) == ["aaa", "bbb"], marks())
check("…and dropping a name with no branch", all(e["branch"] != "nobranch" for e in marks().values()), marks())
check("the review id lives in branch config", git("config", "branch.alpha.stack-review-id") != "")

# flagged and viewed are exclusive; the older {on} body still works
post({"branch": "alpha", "keys": ["ccc"], "state": "flagged"})
check("flagging", marks()["loops:alpha"]["flagged"] == ["ccc"], marks())
post({"branch": "alpha", "keys": ["ccc"], "on": True})
check("viewing a flagged key unflags it", marks()["loops:alpha"]["flagged"] == [] and "ccc" in marks()["loops:alpha"]["keys"], marks())

# unmarking clears the key on every branch
post({"branch": "beta", "keys": ["aaa"], "state": "viewed"})
post({"branch": "beta", "keys": ["aaa"], "state": "none"})
check("none clears a key everywhere", all("aaa" not in e["keys"] for e in marks().values()), marks())

# a rename keeps the marks; a deleted branch's marks go on the next write
git("branch", "-m", "alpha", "alpha-renamed")
check("marks follow git branch -m", "loops:alpha-renamed" in marks() and "loops:alpha" not in marks(), list(marks()))
post({"branch": "gone", "keys": ["ggg"], "state": "viewed"})
git("branch", "-D", "gone")
post({"branch": "beta", "keys": ["hhh"], "state": "viewed"})
ids = {i for i in json.load(open(store))["subjects"]}
check("a deleted branch's marks are pruned", len(ids) == 2 and "loops:gone" not in marks(), ids)

# bad input is refused
check("an unknown state is refused", post({"branch": "beta", "keys": ["x"], "state": "maybe"}).status == 400)
check("a malformed key is refused", post({"branch": "beta", "keys": ["X!"], "state": "viewed"}).status == 400)
check("a branch that doesn't exist is refused, and gets no review id",
      post({"branch": "__probe__", "keys": ["x"], "state": "viewed"}).status == 400
      and subprocess.run(["git", "-C", repo, "config", "branch.__probe__.stack-review-id"], capture_output=True).returncode != 0)
r = post({"branch": "beta", "marks": {"mmm": "flagged", "nnn": "viewed"}})
check("a mixed marks body sets each", r.status == 200 and "mmm" in marks()["loops:beta"]["flagged"] and "nnn" in marks()["loops:beta"]["keys"], marks())
check("a context-suffixed key is accepted", post({"branch": "beta", "keys": ["abc.d3f"], "state": "viewed"}).status == 200)

# a flag keeps where it was made, for the list of flags
post({"branch": "beta", "marks": {"fff": "flagged"}, "where": {"fff": {"path": "a/b.ts", "line": 12, "text": "  const x =\n  1"}}})
f = next((f for f in marks()["loops:beta"]["flags"] if f["key"] == "fff"), {})
check("a flag keeps its file, line and text", f.get("path") == "a/b.ts" and f.get("line") == 12 and f.get("text") == "const x = 1", f)
post({"branch": "beta", "marks": {"fff": "flagged"}, "where": {"fff": {"path": "a/b.ts", "line": 14, "text": "x"}}})
g = next((f for f in marks()["loops:beta"]["flags"] if f["key"] == "fff"), {})
check("…a re-flag moves it and keeps when", g.get("line") == 14 and g.get("at") == f.get("at"), g)
check("a flag made without where still lists", any(f["key"] == "mmm" and f["path"] == "" for f in marks()["loops:beta"]["flags"]), marks()["loops:beta"]["flags"])
check("a bad where is dropped, the flag kept", post({"branch": "beta", "marks": {"ggg": "flagged"}, "where": {"ggg": {"path": 3}}}).status == 200
      and "ggg" in marks()["loops:beta"]["flagged"])
post({"branch": "beta", "marks": {"fff": "viewed"}})
check("reading a flag drops it from the list", all(f["key"] != "fff" for f in marks()["loops:beta"]["flags"]), marks()["loops:beta"]["flags"])

print("viewed: all passed" if failures == 0 else f"viewed: {failures} failed")
sys.exit(1 if failures else 0)
