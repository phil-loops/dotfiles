#!/usr/bin/env python3
"""srv/focus.py learns who merged on the tick that sees trunk move. A squash-merge is a trunk move,
but the merged set came from a cache up to two minutes old, so the tick that fast-forwarded main
found nothing landed and the forest waited another poll (2026-11-23: #11769 merged at 11:27:50,
the 11:28:41 tick moved main, contraction ran at 11:30:37). Temp repo with no remote: origin/main
is written with update-ref and GitHub's answer is a stand-in."""
import testenv  # noqa: F401,E402 — git here ignores the machine's config (testenv.py)
import os
import subprocess
import sys
import tempfile
import time

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
root = tempfile.mkdtemp(prefix="focus-trunk-")
repo = os.path.join(root, "r")
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True, env=env)


def git(*a):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, env=env, check=True).stdout.strip()


git("commit", "-q", "--allow-empty", "-m", "base")
git("update-ref", "refs/remotes/origin/main", "main")
git("branch", "p", "main")
git("config", "branch.p.stack-parent", "main"); git("config", "branch.p.stack-project", "proj")
git("config", "--add", "stack-project.proj.branch", "p")

ctx.CWD = ctx.MAIN_WT = repo
ctx.SCRIPTS = HERE
ctx.ROOT = root
ctx.run = lambda argv, **kw: subprocess.run(argv, cwd=repo, capture_output=True, text=True, env=env)
ctx.log = lambda *a, **k: None
ctx.fire = lambda *a, **k: None
from srv import focus, repostate, restack, sync  # noqa: E402

restack.blocked = lambda: False
focus._live_cwds = lambda: set()
GITHUB = {"prs": {}, "asked": 0}


def fetch_pr_state():
    GITHUB["asked"] += 1
    return dict(GITHUB["prs"])


sync._fetch_pr_state = fetch_pr_state
seen = []
focus._contract_project = lambda project, merged, st, cwds: seen.append((project, dict(merged))) or False


def tick():
    repostate.invalidate()
    focus.tick()


tick()
check("the first sight of trunk asks GitHub once", GITHUB["asked"] == 1, GITHUB)
tick()
check("a tick with trunk where it was asks nothing", GITHUB["asked"] == 1, GITHUB)
check("…and finds nothing landed", seen == [], seen)

# p's PR squash-merges: trunk moves, and the cache (seconds old) still says nothing merged
git("commit", "-q", "--allow-empty", "-m", "p (#1)")
git("update-ref", "refs/remotes/origin/main", "main")
GITHUB["prs"] = {"p": {"state": "MERGED", "head": git("rev-parse", "p")}}
check("the cache alone wouldn't know yet", time.time() - sync._pr_state_ent(repo)["at"] < sync._PR_STATE_TTL
      and sync._pr_state_ent(repo)["data"] == {})
tick()
check("the tick that sees trunk move asks GitHub again", GITHUB["asked"] == 2, GITHUB)
check("…and contracts what merged on that same tick", seen == [("proj", {"p": git("rev-parse", "p")})], seen)

print(f"\n{'all passed' if not failures else f'{failures} failed'}")
sys.exit(1 if failures else 0)
