#!/usr/bin/env python3
"""srv/repostate.py tree lookups: a branch tip's tree reads every head in one spawn, a new
snapshot (any config write) reads none, and only a moved tip pays again."""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from srv import ctx  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
repo = tempfile.mkdtemp(prefix="repostate-trees-")
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)


def git(*a):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, env=env, check=True).stdout.strip()


spawns = []
ctx.CWD = ctx.MAIN_WT = repo


def run(argv, **kw):
    spawns.append(argv[:2] + argv[2:3])
    return subprocess.run(argv, cwd=repo, capture_output=True, text=True, env=env)


ctx.run = run
from srv import repostate  # noqa: E402

for i, b in enumerate(("main", "a", "b")):
    git("checkout", "-q", "-B", b)
    with open(os.path.join(repo, f"{b}.txt"), "w") as f:
        f.write(b)
    git("add", "."); git("commit", "-q", "-m", b)


def fresh():
    repostate.invalidate()
    snap = repostate.snapshot()
    spawns.clear()
    return snap


snap = fresh()
want = {b: git("rev-parse", f"{b}^{{tree}}") for b in ("main", "a", "b")}
check("a branch's tree by name is its tip's tree", snap.tree("a") == want["a"], snap.tree("a"))
check("…and by commit sha", snap.tree(git("rev-parse", "b")) == want["b"])
check("every head's tree came from one spawn", [s[:2] for s in spawns] == [["git", "for-each-ref"]], spawns)
check("head_trees lists every branch", snap.head_trees() == want, snap.head_trees())

git("config", "branch.a.stack-parent", "main")
snap = fresh()
snap.tree("a"); snap.head_trees(); snap.tree("b")
check("a new snapshot with the same tips reads no tree", spawns == [], spawns)

git("checkout", "-q", "a")
with open(os.path.join(repo, "a.txt"), "w") as f:
    f.write("a2")
git("commit", "-qam", "a2")
snap = fresh()
check("a moved tip reads its new tree", snap.tree("a") == git("rev-parse", "a^{tree}") and len(spawns) == 1, spawns)
check("a rev that isn't a head still resolves", snap.tree("a~1") == want["a"])

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
