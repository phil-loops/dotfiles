#!/usr/bin/env python3
"""srv/push.py's conform: when origin's copy of a published branch was rewritten upstream and
already carries everything local has, local takes origin's copy (tooling-doctor P6/P7). Both of
2026-11-17's GitHub rewrites, built as real commits — origin's refs are written with update-ref,
so nothing is pushed or fetched."""
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
for k in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"):
    env.pop(k, None)
repo = os.path.join(tempfile.mkdtemp(prefix="push-conform-"), "r")
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True, env=env)
os.chdir(repo)
ctx.run = lambda argv, **kw: subprocess.run(argv, capture_output=True, text=True, env=env)
from srv import push  # noqa: E402


def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True, env=env, check=True).stdout.strip()


def write(path, text):
    with open(path, "w") as f:
        f.write(text)


def commit(path, text, msg):
    write(path, text)
    git("add", path)
    git("commit", "-q", "-m", msg)
    return git("rev-parse", "HEAD")


def origin(branch, sha):
    git("update-ref", f"refs/remotes/origin/{branch}", sha)


m0 = commit("base.txt", "base\n", "root")

# 1 · GitHub's Update-branch (rebase): b's one commit replayed onto a newer main
git("checkout", "-q", "-b", "b")
commit("b.txt", "b\n", "b1")
git("checkout", "-q", "main")
m1 = commit("main.txt", "main moved\n", "main moves")
git("checkout", "-q", "-b", "gh-b", m1)
commit("b.txt", "b\n", "b1 (rebased by GitHub)")
origin("b", git("rev-parse", "HEAD"))
git("checkout", "-q", "main")
check("update-branch rebase: origin already has everything local has", push.origin_has_local("b"))
ok, words = push.conform_to_origin("b")
check("update-branch rebase: local takes origin's copy", ok and git("rev-parse", "b") == git("rev-parse", "origin/b"), words)

# 2 · a base PR squash-merges; GitHub retargets the child to main and rebases it
git("checkout", "-q", "-b", "p", m0)
commit("p.txt", "p1\n", "p1")
commit("p.txt", "p1\np2\n", "p2")
git("checkout", "-q", "-b", "c")
commit("c.txt", "c\n", "c1")
git("checkout", "-q", "-b", "squash", m1)
write("p.txt", "p1\np2\n")
git("add", "p.txt")
git("commit", "-q", "-m", "p (#1) — the squash")
commit("c.txt", "c\n", "c1 (rebased by GitHub)")
origin("c", git("rev-parse", "HEAD"))
git("checkout", "-q", "main")
check("post-merge rebase: the parent's commits live in main's squash, so it still conforms", push.origin_has_local("c"))
ok, words = push.conform_to_origin("c")
check("post-merge rebase: local takes origin's copy", ok and git("rev-parse", "c") == git("rev-parse", "origin/c"), words)

# 3 · origin rewritten, and local added a commit after the work origin carries → replay it
git("checkout", "-q", "-b", "d", m0)
commit("d.txt", "d\n", "d1")
git("checkout", "-q", "-b", "gh-d", m1)
commit("d.txt", "d\n", "d1 (rebased)")
origin("d", git("rev-parse", "HEAD"))
git("checkout", "-q", "d")
commit("d2.txt", "local only\n", "d2")
git("merge", "-q", "--no-edit", "main")
git("checkout", "-q", "main")
check("a newer local commit on rewritten work is not a plain conform", not push.origin_has_local("d"))
check("…its plan is that one commit, the catch-up merge left behind", [git("log", "-1", "--format=%s", c) for c in push.conform_plan("d") or []] == ["d2"], push.conform_plan("d"))
ok, words = push.conform_to_origin("d")
check("…and conform takes origin's copy with d2 replayed on top",
      ok and git("rev-parse", "d^") == git("rev-parse", "origin/d") and git("show", "d:d2.txt") == "local only", words)

# 3b · origin changed the work itself → nothing of local's is carried, never a conform
git("checkout", "-q", "-b", "g", m0)
commit("g.txt", "g\n", "g1")
git("checkout", "-q", "-b", "gh-g", m1)
commit("g.txt", "g, edited on github\n", "g1 (edited)")
origin("g", git("rev-parse", "HEAD"))
git("checkout", "-q", "main")
before = git("rev-parse", "g")
check("origin's own edit to the work is a real divergence", push.conform_plan("g") is None)
ok, _ = push.conform_to_origin("g")
check("…and conform refuses, leaving local where it was", not ok and git("rev-parse", "g") == before)

# 4 · local simply ahead of origin → an ordinary push, not a conform
git("checkout", "-q", "-b", "e", m0)
commit("e.txt", "e\n", "e1")
origin("e", git("rev-parse", "HEAD"))
commit("e.txt", "e\ne2\n", "e2")
git("checkout", "-q", "main")
check("local ahead of origin is not a conform", not push.origin_has_local("e"))

# 5 · a dirty worktree holding the branch is never reset
wt = repo + "-wt"
git("checkout", "-q", "-b", "f", m0)
commit("f.txt", "f\n", "f1")
git("checkout", "-q", "-b", "gh-f", m1)
commit("f.txt", "f\n", "f1 (rebased)")
origin("f", git("rev-parse", "HEAD"))
git("checkout", "-q", "main")
git("worktree", "add", "-q", wt, "f")
write(os.path.join(wt, "f.txt"), "uncommitted\n")
before = git("rev-parse", "f")
ok, words = push.conform_to_origin("f")
check("a dirty holder refuses the conform", not ok and git("rev-parse", "f") == before and "uncommitted" in words, words)
subprocess.run(["git", "-C", wt, "checkout", "-q", "--", "f.txt"], env=env)
ok, words = push.conform_to_origin("f")
check("a clean holder conforms in place", ok and git("-C", wt, "rev-parse", "HEAD") == git("rev-parse", "origin/f"), words)

print("all passed" if not failures else f"{failures} failed")
sys.exit(1 if failures else 0)
