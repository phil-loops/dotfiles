#!/usr/bin/env python3
"""A diff's key names its inputs and only those (repostate.refs_fingerprint, /node's memo key and
state.py's diffStamp): the branch's, its parent's and the trunk's tips move it; a gates verdict, a
review flag or a description written to the branch's config don't (2026-11-24: 5 of 13 /node rebuilds
in half an hour were config writes on unchanged branches). Temp repo, nothing pushed."""
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
repo = os.path.join(tempfile.mkdtemp(prefix="diff-stamp-"), "r")
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True, env=env)
os.chdir(repo)
ctx.run = lambda argv, **kw: subprocess.run(argv, capture_output=True, text=True, env=env, cwd=kw.get("cwd", repo))
ctx.CWD = ctx.MAIN_WT = repo
ctx.log = lambda line: None
from srv import repostate  # noqa: E402


def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True, env=env, check=True).stdout.strip()


def commit(msg):
    with open("f.txt", "a") as f:
        f.write(msg + "\n")
    git("add", "f.txt")
    git("commit", "-q", "-m", msg)


def stamps():
    repostate.invalidate()
    s = repostate.snapshot()
    names = ["c", s.parent("c")]
    return s.refs_fingerprint(names), s.inputs_fingerprint(names)


commit("root")
git("checkout", "-q", "-b", "p")
commit("p1")
git("checkout", "-q", "-b", "c")
commit("c1")
git("config", "branch.c.stack-parent", "p")
diff0, read0 = stamps()

for key, value in (("stack-gates-green-tree", "abc"), ("stack-review-flag", "x"), ("description", "rewritten by an agent")):
    git("config", f"branch.c.{key}", value)
    git("config", f"branch.p.{key}", value)
    d, r = stamps()
    check(f"{key} on the branch or its parent leaves the diff's key", d == diff0, key)
    check(f"…while the wider read stamp moves for it (the flags read it)", r != read0, key)
    read0 = r

commit("c2")
d, _ = stamps()
check("a commit on the branch moves the diff's key", d != diff0)
diff0 = d
git("checkout", "-q", "p")
commit("p2")
d, _ = stamps()
check("a commit on the parent moves it", d != diff0)
diff0 = d
git("update-ref", "refs/remotes/origin/main", "main")
d, _ = stamps()
check("the trunk's origin copy moving moves it", d != diff0)
diff0 = d
git("branch", "q", "main")
git("config", "branch.c.stack-parent", "q")
repostate.invalidate()
s = repostate.snapshot()
check("a reparent moves it (the parent is one of its names)", s.refs_fingerprint(["c", s.parent("c")]) != diff0)

print(f"\n{'OK' if not failures else 'FAILED'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
