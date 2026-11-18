#!/usr/bin/env python3
"""srv/push.py's door per P5 (tooling-doctor B4): a follow-up onto an open PR pushes with its gates
advising — the door names what's red and lets it go — while a first push still needs them and a
red squawk blocks either way. A temp repo; origin's refs are written with update-ref and the open
PR set and the gate run are stand-ins, so nothing is pushed, fetched or asked of GitHub."""
import os
import subprocess
import sys
import tempfile

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


env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
for k in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"):
    env.pop(k, None)
repo = os.path.join(tempfile.mkdtemp(prefix="push-door-"), "r")
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True, env=env)
os.chdir(repo)
ctx.run = lambda argv, **kw: subprocess.run(argv, capture_output=True, text=True, env=env)
ctx.CWD = ctx.MAIN_WT = repo
from srv import push, repostate, openprs, sync, verdicts  # noqa: E402

OPEN = set()
openprs.heads = lambda fresh=False: set(OPEN)
sync._deploy_critical = lambda b: []
push._origin_web = lambda b: ""
push._review_flags = lambda b: {}
verdicts.waived = lambda b, tree: None


class Run:
    def __init__(self, tree, gates, alive=False):
        self.meta = {"tree": tree}
        self._gates, self._alive = gates, alive

    def alive(self):
        return self._alive


RUN = {"run": None}
push.gate_run = lambda b: RUN["run"]
push.gate_result = lambda run: {"event": "result", "ok": all(g["ok"] for g in run._gates), "gates": run._gates}


def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True, env=env, check=True).stdout.strip()


def commit(path, text, msg, body=""):
    with open(path, "w") as f:
        f.write(text)
    git("add", path)
    git("commit", "-q", "-m", msg, *(["-m", body] if body else []))
    return git("rev-parse", "HEAD")


def verdict(b):
    repostate.invalidate()
    return push._origin_verdict(b)


def gates_ward(v):
    return next(w for w in v["wards"] if w["k"] == "gates")


m0 = commit("base.txt", "base\n", "root")
git("update-ref", "refs/remotes/origin/main", m0)
git("checkout", "-q", "-b", "b")
git("config", "branch.b.stack-parent", "main")
git("config", "branch.b.description", "add b")
first = commit("b.txt", "b\n", "feat: add b", "why b")

# 1 · a first push: gates still hold the door
v = verdict("b")
check("first push without gates is refused", not v["ok"] and not gates_ward(v)["advisory"], v["reasons"])

# 2 · a follow-up onto an open PR: gates advise, the push goes
git("update-ref", "refs/remotes/origin/b", first)
OPEN.add("b")
commit("b.txt", "b fixed\n", "apply review fix")
tree = git("rev-parse", "HEAD^{tree}")
v = verdict("b")
check("follow-up with no gates run pushes", v["ok"], v["reasons"])
check("…and the gates ward advises", gates_ward(v)["advisory"] and not gates_ward(v)["ok"], gates_ward(v))
check("…saying CI checks it", "CI checks it" in gates_ward(v)["why"], gates_ward(v)["why"])

RUN["run"] = Run(tree, [{"name": "lint", "ok": False}, {"name": "tests", "ok": True}])
v = verdict("b")
check("follow-up with a red lint pushes", v["ok"], v["reasons"])
check("…naming the red gate", "lint" in gates_ward(v)["why"], gates_ward(v)["why"])

# 3 · a red squawk blocks even a follow-up
RUN["run"] = Run(tree, [{"name": "squawk", "ok": False}, {"name": "lint", "ok": True}])
v = verdict("b")
check("follow-up with a red squawk is refused", not v["ok"] and not gates_ward(v)["advisory"], v["reasons"])
check("…saying squawk", "squawk" in gates_ward(v)["why"], gates_ward(v)["why"])

# 4 · a run for an older tree, or one still going, names nothing
RUN["run"] = Run("0" * 40, [{"name": "squawk", "ok": False}])
check("a red from another tree is not this tree's", push.tree_reds("b", tree) == [])
RUN["run"] = Run(tree, [{"name": "squawk", "ok": False}], alive=True)
check("a run still going has no reds yet", push.tree_reds("b", tree) == [])

# 5 · the PR closes: the branch is a first push again as far as the door goes
OPEN.clear()
RUN["run"] = None
v = verdict("b")
check("no open PR: gates hold the door again", not gates_ward(v)["advisory"], gates_ward(v))

# 6 · pregate's follow-up candidates: open PR, origin an ancestor of a local that's ahead
from srv import pregate  # noqa: E402
OPEN.add("b")
repostate.invalidate()
snap = repostate.snapshot()
check("pregate finds the follow-up", list(pregate._followups(snap)) == ["b"], list(pregate._followups(snap)))
git("update-ref", "refs/remotes/origin/b", git("rev-parse", "b"))
repostate.invalidate()
snap = repostate.snapshot()
check("…and not once origin has it", list(pregate._followups(snap)) == [], list(pregate._followups(snap)))

print(f"\n{'all passed' if not failures else f'{failures} failed'}")
sys.exit(1 if failures else 0)
