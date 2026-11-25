#!/usr/bin/env python3
"""One trunk spelling (srv/repostate.py trunk/diff_base): with local main behind origin's, a
root branch's own diff and a commit stretch lit from main both start at origin's copy, so
origin's newer commits never read as the branch's."""
import testenv  # noqa: F401,E402 — git here ignores the machine's config (testenv.py)
import json
import os
import subprocess
import sys
import tempfile
from urllib.parse import urlparse

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
root = tempfile.mkdtemp(prefix="trunk-base-")
origin, repo = os.path.join(root, "o.git"), os.path.join(root, "r")
subprocess.run(["git", "init", "-q", "--bare", origin], check=True)
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)


def git(*a):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, env=env, check=True).stdout.strip()


def commit(path, text, msg):
    with open(os.path.join(repo, path), "w") as f:
        f.write(text)
    git("add", "."); git("commit", "-q", "-m", msg)


ctx.CWD = ctx.MAIN_WT = repo
ctx.run = lambda argv, **kw: subprocess.run(argv, cwd=repo, capture_output=True, text=True, env=env)
from srv import repostate, review  # noqa: E402

git("remote", "add", "origin", origin)
commit("a.txt", "a\n", "root"); git("push", "-q", "origin", "main")
# origin's main moves on; local main stays behind (a dirty main worktree skips the fast-forward)
git("checkout", "-q", "-b", "elsewhere")
commit("merged.txt", "someone else's\n", "merged elsewhere"); git("push", "-q", "origin", "elsewhere:main")
git("fetch", "-q", "origin")
git("checkout", "-q", "-b", "feat", "origin/main")
commit("feat.txt", "mine\n", "feat: mine")
git("checkout", "-q", "main")
git("config", "branch.feat.stack-parent", "main")
repostate.invalidate()
snap = repostate.snapshot()

check("the trunk is origin's copy", snap.trunk() == "origin/main", snap.trunk())
check("a root branch's diff starts at it", snap.diff_base("feat") == "origin/main", snap.diff_base("feat"))
git("config", "branch.child.stack-parent", "feat")
repostate.invalidate()
check("a stacked branch's starts at its parent", repostate.snapshot().diff_base("child") == "feat")


class Req:
    def _send(self, status, body):
        self.status, self.body = status, json.loads(body)


r = Req()
review.commit_diff(r, urlparse(f"/commit-diff?sha={git('rev-parse', 'feat')}&from=main"))
paths = sorted(f.get("path") or f.get("new") or "" for f in (r.body.get("files") or []))
check("a stretch lit from main holds only the branch's own file", r.status == 200 and paths == ["feat.txt"], (r.status, paths))

# what a review's card asks: the change since the tip Phil saw, that tip's own change left out, one file of it
seen = git("rev-parse", "feat")
git("checkout", "-q", "feat")
commit("feat.txt", "mine, revised\n", "revise"); commit("other.txt", "x\n", "another file")
git("checkout", "-q", "main")
r = Req()
review.commit_diff(r, urlparse(f"/commit-diff?sha={git('rev-parse', 'feat')}&since={seen}&path=feat.txt"))
files = r.body.get("files") or []
check("since a commit is exactly what came after it, kept to the one file",
      r.status == 200 and [f["path"] for f in files] == ["feat.txt"] and "+mine, revised" in files[0]["patch"] and "-mine" in files[0]["patch"],
      (r.status, files))
r = Req()
review.commit_diff(r, urlparse(f"/commit-diff?sha={git('rev-parse', 'feat')}&since=main"))
check("since takes a sha, never a moving name", r.status == 400, r.status)

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
