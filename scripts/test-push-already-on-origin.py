#!/usr/bin/env python3
"""srv/push.py's already_on_origin: p on a branch origin already holds is a push that already
happened, not a failure — true only when origin's copy is exactly the local tip."""
import testenv  # noqa: F401,E402 — git here ignores the machine's config (testenv.py)
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
root = tempfile.mkdtemp(prefix="push-already-")
origin, repo = os.path.join(root, "o.git"), os.path.join(root, "r")
subprocess.run(["git", "init", "-q", "--bare", origin], check=True)
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)
ctx.run = lambda argv, **kw: subprocess.run(argv, capture_output=True, text=True, cwd=repo, env=env)
from srv.push import already_on_origin  # noqa: E402


def git(*a):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, env=env, check=True).stdout.strip()


def publish(ref):
    """What a push of `ref` leaves, without pushing: the fixture remote fetches it from here, and
    this repo's remote-tracking ref follows. (Builds here never push, even to a fixture remote.)"""
    subprocess.run(["git", "--git-dir", origin, "fetch", "-q", repo, f"{ref}:{ref}"], check=True, env=env, capture_output=True)
    git("update-ref", f"refs/remotes/origin/{ref}", ref)


git("remote", "add", "origin", origin)
git("commit", "-q", "--allow-empty", "-m", "root")
git("checkout", "-q", "-b", "b")
git("commit", "-q", "--allow-empty", "-m", "b1")
check("a branch never pushed is not on origin", not already_on_origin("b"))
publish("b")
check("a branch whose tip origin holds is already on origin", already_on_origin("b"))
git("commit", "-q", "--allow-empty", "-m", "b2")
check("a branch with a commit origin lacks is not", not already_on_origin("b"))
check("a branch that doesn't exist is not", not already_on_origin("nope"))

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
