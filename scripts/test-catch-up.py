#!/usr/bin/env python3
"""srv/catchup.py: a chain falls behind from above and catches up top-down — published links by a
catch-up merge (append-only, the parent's tip becomes an ancestor), unpublished links by a rebase.
Temp repo; origin refs written with update-ref, so nothing is pushed or fetched."""
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

env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
for k in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"):
    env.pop(k, None)
root = tempfile.mkdtemp(prefix="catch-up-")
repo = os.path.join(root, "r")
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True, env=env)
os.chdir(repo)
ctx.run = lambda argv, **kw: subprocess.run(argv, capture_output=True, text=True, env=env, cwd=kw.get("cwd", repo))
ctx.MAIN_WT = repo
from srv import catchup  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


def git(*a, ok=True):
    return subprocess.run(["git", *a], capture_output=True, text=True, env=env, check=ok).stdout.strip()


def commit(path, text, msg):
    with open(path, "w") as f:
        f.write(text)
    git("add", path)
    git("commit", "-q", "-m", msg)


def anc(a, b):
    return subprocess.run(["git", "merge-base", "--is-ancestor", a, b], env=env).returncode == 0


commit("base.txt", "base\n", "root")
for b, parent in (("a", "main"), ("b", "a"), ("c", "b")):
    git("checkout", "-q", "-b", b)
    commit(f"{b}.txt", f"{b}\n", f"{b}1")
    git("config", f"branch.{b}.stack-parent", parent)
git("update-ref", "refs/remotes/origin/a", "a")
git("update-ref", "refs/remotes/origin/b", "b")          # a and b published, c local only
git("checkout", "-q", "a")
commit("a2.txt", "a moved\n", "a2")                       # the grandparent of c moves
git("checkout", "-q", "main")
b_before, c_before = git("rev-parse", "b"), git("rev-parse", "c")

check("c's own parent hasn't moved, but its chain owes a catch-up at b", not catchup.off_parent("c") and catchup.owes("c") == "b")
res = catchup.catch_up("c")
check("the walk catches up b, then c", res["ok"] and [m["branch"] for m in res["moved"]] == ["b", "c"], res)
check("published b got a catch-up merge, not a rewrite", res["moved"][0]["how"] == "merged" and anc(b_before, "b") and anc("a", "b"))
check("…its merge's parents are b's old tip and a's tip", git("rev-list", "--parents", "-n1", "b").split()[1:] == [b_before, git("rev-parse", "a")])
check("unpublished c was rebased onto the caught-up b", res["moved"][1]["how"] == "rebased" and anc("b", "c") and not anc(c_before, "c"))
check("c carries a's new commit and its own", os.path.exists("a2.txt") is False and git("show", "c:a2.txt") == "a moved" and git("show", "c:c.txt") == "c")
check("nothing is owed after", catchup.owes("c") == "")

# a conflict stops the walk with nothing half-done
git("checkout", "-q", "a")
commit("b.txt", "a writes b's file\n", "a3 conflicts with b")
git("checkout", "-q", "main")
b_before = git("rev-parse", "b")
res = catchup.catch_up("c")
check("a conflicting link stops the walk and says where", not res["ok"] and res["stopped"]["branch"] == "b", res)
check("…leaving b exactly where it was", git("rev-parse", "b") == b_before)
print("all passed" if not failures else f"{failures} failed")
sys.exit(1 if failures else 0)
