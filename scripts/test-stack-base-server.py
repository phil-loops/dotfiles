#!/usr/bin/env python3
"""The server's branch-base record against a throwaway repo: a forward rebase by the sync path
records the base it produced, and the reseat walk's cut point comes from stack-base's one rule
(a record the child was rebased past is replaced, a parent rewritten backwards keeps it)."""
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


root = tempfile.mkdtemp(prefix="stack-base-server-")
origin = os.path.join(root, "origin.git")
repo = os.path.join(root, "repo")
env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
       "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}


def git(*args, cwd=None):
    return subprocess.run(["git", "-C", cwd or repo, *args], capture_output=True, text=True, env=env, check=True).stdout.strip()


def commit(msg, cwd=None):
    git("commit", "-q", "--allow-empty", "-m", msg, cwd=cwd)
    return git("rev-parse", "HEAD", cwd=cwd)


subprocess.run(["git", "init", "-q", "--bare", origin], check=True)
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)
git("remote", "add", "origin", origin)
root_sha = commit("root")
git("push", "-q", "origin", "main")

ctx.CWD = ctx.MAIN_WT = repo
ctx.SCRIPTS = HERE
ctx.run = lambda argv, **kw: subprocess.run(argv, cwd=repo, capture_output=True, text=True, env=env)
from srv import reviews, sync  # noqa: E402

# p off main with a child c; both bases recorded at their fork points
git("checkout", "-q", "-b", "p")
p1 = commit("p1")
git("config", "branch.p.stack-parent", "main")
git("config", "branch.p.stack-base", root_sha)
git("checkout", "-q", "-b", "c")
commit("c1")
git("config", "branch.c.stack-parent", "p")
git("config", "branch.c.stack-base", p1)

# main advances; p and c are rebased forward by hand, the records left behind (the focus
# auto-sync of 2026-10-28)
git("checkout", "-q", "main")
m1 = commit("m1")
git("rebase", "-q", "main", "p")
p1_new = git("rev-parse", "p")
git("rebase", "-q", "--onto", "p", p1, "c")
git("checkout", "-q", "main")

cut = reviews._cut_point("p", "c")
check("a child rebased past its record cuts at the new fork point", cut == p1_new, f"{cut} vs {p1_new} (record {p1})")
check("…and the record is healed", git("config", "branch.c.stack-base") == p1_new)

# p is rewritten backwards (amended); c still holds p's old tip, which the record names
git("checkout", "-q", "p")
git("commit", "-q", "--amend", "--allow-empty", "-m", "p1 reworded")
git("checkout", "-q", "main")
cut = reviews._cut_point("p", "c")
check("a parent rewritten backwards keeps the child's record as its cut", cut == p1_new, f"{cut} vs {p1_new}")

# a root branch behind origin/main: the sync path's forward rebase records the new base
git("checkout", "-q", "-b", "a", root_sha)
commit("a1")
git("config", "branch.a.stack-parent", "main")
git("config", "branch.a.stack-base", root_sha)
git("checkout", "-q", "main")
git("push", "-q", "origin", "main")
status, summary = sync._direct_rebase("a")
check("the sync rebase lands", status == "clean", f"{status} {summary}")
check("…and records the base it produced", git("config", "branch.a.stack-base") == m1,
      f"{git('config', 'branch.a.stack-base')} vs {m1}")
check("…which is a's fork point", git("merge-base", "main", "a") == m1)

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
