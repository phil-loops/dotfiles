#!/usr/bin/env python3
"""srv/focus.py's sync decision with a published root: the restack runs with that root's subtree
held while the other root moves; when only the held subtree is behind, the forest is skipped."""
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
root = tempfile.mkdtemp(prefix="focus-hold-")
origin, repo = os.path.join(root, "o.git"), os.path.join(root, "r")
subprocess.run(["git", "init", "-q", "--bare", origin], check=True)
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)


def git(*a):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, env=env, check=True).stdout.strip()


def mk(b, parent):
    git("checkout", "-q", "-b", b, parent)
    with open(os.path.join(repo, f"{b}.txt"), "w") as f:
        f.write(b)
    git("add", f"{b}.txt"); git("commit", "-q", "-m", b)
    git("config", f"branch.{b}.stack-parent", parent); git("config", f"branch.{b}.stack-project", "proj")
    git("config", "--add", "stack-project.proj.branch", b)


git("remote", "add", "origin", origin)
git("commit", "-q", "--allow-empty", "-m", "base"); git("push", "-q", "origin", "main")
mk("a", "main"); mk("b", "main"); mk("c", "b")
git("push", "-q", "origin", "b")
git("checkout", "-q", "main"); git("commit", "-q", "--allow-empty", "-m", "m1"); git("push", "-q", "origin", "main")

ctx.CWD = ctx.MAIN_WT = repo
ctx.SCRIPTS = HERE
ctx.ROOT = root
ctx.run = lambda argv, **kw: subprocess.run(argv, cwd=repo, capture_output=True, text=True, env=env)
ctx.log = lambda *a, **k: None
from srv import focus, sync  # noqa: E402

sync._open_pr_heads = lambda *a, **k: {"b"}
sync._already_merged = lambda b: False
focus._busy = lambda branches, cwds: ""
calls = []


def fake_restack(project, hold=()):
    calls.append((project, tuple(hold)))
    for b in focus._members(project):
        if b not in hold and focus._parent(b) == "main":
            git("rebase", "-q", "origin/main", b)   # the walk moves the free roots
    git("checkout", "-q", "main")
    return 0, ""


focus._restack = fake_restack

st = {"projects": {}}
changed = focus._sync_project("proj", st, {})
check("the forest restacks with the published root held", calls == [("proj", ("b",))], calls)
check("…and reads synced afterwards, the held subtree behind on purpose", st["projects"]["proj"].get("state") == "synced", st["projects"]["proj"])
check("a moved onto fresh main", subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", "origin/main", "a"], env=env).returncode == 0)
check("b and c stayed", subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", "origin/main", "b"], env=env).returncode != 0)

# only the held subtree is behind now: nothing to do, said as the open PR
calls.clear()
st = {"projects": {}}
focus._sync_project("proj", st, {})
check("a forest whose only behind branches are held is skipped", calls == [] and st["projects"]["proj"] == {"state": "skipped", "why": "its base has an open PR"}, (calls, st))

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
