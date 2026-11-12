#!/usr/bin/env python3
"""srv/push.py's outgoing range: a stacked branch counts past its parent, a root past main or
every remote, and a re-push past origin's copy — the pure range builder, then one real repo."""
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


ctx.run = lambda argv, **kw: subprocess.run(argv, capture_output=True, text=True)
from srv.push import _outgoing_range  # noqa: E402

exists = lambda b: b in {"main", "p", "c"}  # noqa: E731
check("a root's first push is past every remote", _outgoing_range("p", False, "main", "main", exists) == ["p", "--not", "--remotes=origin"])
check("a child's first push is also past its parent", _outgoing_range("c", False, "p", "main", exists) == ["c", "--not", "--remotes=origin", "p"])
check("a child's re-push is past origin's copy and its parent", _outgoing_range("c", True, "p", "main", exists) == ["origin/c..c", "--not", "p"])
check("a root's re-push is past origin's copy alone", _outgoing_range("p", True, "main", "main", exists) == ["origin/p..p"])
check("a parent that no longer exists is not named", _outgoing_range("c", False, "gone", "main", exists) == ["c", "--not", "--remotes=origin"])

# the range against git: parent p has two unpushed commits, child c one of its own
env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
root = tempfile.mkdtemp(prefix="push-range-")
origin, repo = os.path.join(root, "o.git"), os.path.join(root, "r")
subprocess.run(["git", "init", "-q", "--bare", origin], check=True)
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)


def git(*a):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, env=env, check=True).stdout.strip()


git("remote", "add", "origin", origin)
git("commit", "-q", "--allow-empty", "-m", "root")
git("push", "-q", "origin", "main")
git("checkout", "-q", "-b", "p")
git("commit", "-q", "--allow-empty", "-m", "p1")
git("commit", "-q", "--allow-empty", "-m", "p2")
git("checkout", "-q", "-b", "c")
git("commit", "-q", "--allow-empty", "-m", "c1")
n = len(git("rev-list", *_outgoing_range("c", False, "p", "main", exists)).split())
check("git counts the child's one commit, not the parent's two as well", n == 1, n)

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
