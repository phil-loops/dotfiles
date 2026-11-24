#!/usr/bin/env python3
"""One answer to "who can see this branch" (repostate.visibility: pr / draft / local), and the
writers that ask it: sync's rebase declares a draft rewrite to the published-history hook, the push
door never rebases a pushed draft on its own, and a diverged draft goes to Phil's replace — never to
a Claude pane (2026-11-16: the door rewrote a pushed no-PR branch, then refused the divergence it
made). Temp repo with the real hook installed; origin refs written with update-ref, the open-PR
set a stand-in — nothing is pushed, fetched or asked of GitHub."""
import testenv  # noqa: F401,E402 — git here ignores the machine's config (testenv.py)
import json
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
for k in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE", "STACK_REWRITE_PUBLISHED", "CLAUDE_CODE_SESSION_ID", "STACK_INITIATOR", "TMUX"):
    env.pop(k, None)
    os.environ.pop(k, None)
repo = os.path.join(tempfile.mkdtemp(prefix="draft-vis-"), "r")
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True, env=env)
os.chdir(repo)
os.symlink(os.path.join(HERE, "..", "hooks", "loops-reference-transaction"), os.path.join(repo, ".git", "hooks", "reference-transaction"))
ctx.run = lambda argv, **kw: subprocess.run(argv, capture_output=True, text=True, env=env, cwd=kw.get("cwd", repo))
ctx.CWD = ctx.MAIN_WT = repo
ctx.log = lambda line: None
from srv import push, rebaseguard, repostate, openprs, sync, verdicts  # noqa: E402

OPEN = set()
OUTAGE = [False]
openprs.heads = lambda fresh=False: set(OPEN)
openprs.failed = lambda: OUTAGE[0]
sync._deploy_critical = lambda b: []
push._origin_web = lambda b: ""
push._review_flags = lambda b: {}
verdicts.waived = lambda b, tree: None
push.gate_run = lambda b: None


def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True, env=env, check=True).stdout.strip()


def commit_on(branch, path, text, msg):
    git("checkout", "-q", branch)
    with open(path, "w") as f:
        f.write(text)
    git("add", path)
    git("commit", "-q", "-m", msg)
    git("checkout", "-q", "main")
    return git("rev-parse", branch)


class Req:
    def _send(self, code, body, *a):
        self.code, self.body = code, json.loads(body)


def prep(b):
    repostate.invalidate()
    r = Req()
    push.prep_push(r, json.dumps({"branch": b}))
    return r.body


def vis(b):
    repostate.invalidate()
    return repostate.snapshot().visibility(b)


with open("base.txt", "w") as f:
    f.write("base\n")
git("add", "base.txt")
git("commit", "-q", "-m", "root")
git("update-ref", "refs/remotes/origin/main", "main")

# ── the one answer ──
git("branch", "l")
commit_on("l", "l.txt", "l\n", "l1")
git("branch", "d", "main")
commit_on("d", "d.txt", "d\n", "d1")
git("update-ref", "refs/remotes/origin/d", "d")
git("branch", "p", "main")
commit_on("p", "p.txt", "p\n", "p1")
git("update-ref", "refs/remotes/origin/p", "p")
OPEN.add("p")
check("never pushed reads local", vis("l") == "local", vis("l"))
check("pushed with no PR reads draft", vis("d") == "draft", vis("d"))
check("an open PR reads pr", vis("p") == "pr", vis("p"))
OUTAGE[0] = True
check("gh unreachable: a pushed branch it can't verify reads pr", vis("d") == "pr", vis("d"))
check("gh unreachable: never pushed still reads local", vis("l") == "local", vis("l"))
OUTAGE[0] = False

# main moves on: every branch is behind
git("checkout", "-q", "main")
with open("main.txt", "w") as f:
    f.write("main moved\n")
git("add", "main.txt")
git("commit", "-q", "-m", "main moves")
git("update-ref", "refs/remotes/origin/main", "main")

# ── sync's rebase declares a draft rewrite; the hook refuses an undeclared one ──
wt = os.path.join(os.path.dirname(repo), "wt")
git("worktree", "add", "-q", "--detach", wt, "main")
git("-C", wt, "checkout", "-q", "d")
d_before = git("rev-parse", "d")
r = rebaseguard.run(wt, ["origin/main"])
check("an undeclared rebase of a draft is refused by the hook", r.returncode != 0 and git("rev-parse", "d") == d_before, r.stderr[-200:])
r = rebaseguard.run(wt, ["origin/main"], rewrite="d")
check("a declared rebase of a draft lands", r.returncode == 0 and git("rev-parse", "d") != d_before, r.stderr[-200:])
git("-C", wt, "checkout", "-q", "--detach")
st = sync.state("p")
check("sync never calls an open PR syncable", not st["syncable"], st)

# ── the door: a diverged draft goes to Phil's replace, not to Claude ──
body = prep("d")
check("a diverged draft answers replace, never reconcile", body.get("replace") is True and not body.get("reconcile"), body)

# ── the door never rebases a pushed draft on its own ──
git("branch", "e", git("rev-parse", "main~1"))
commit_on("e", "e.txt", "e\n", "e1")
git("update-ref", "refs/remotes/origin/e", "e")
commit_on("e", "e.txt", "e2\n", "e2")
e_before = git("rev-parse", "e")
st = sync.state("e")
check("sync calls a behind draft at the root syncable (Phil's press rebases it, declared)", st["syncable"] and not st["published"], st)
body = prep("e")
on_main = subprocess.run(["git", "merge-base", "--is-ancestor", "main", "e"], env=env).returncode == 0
check("a behind draft keeps its base through the door", not on_main and subprocess.run(["git", "merge-base", "--is-ancestor", e_before, "e"], env=env).returncode == 0, body)
check("…and the door says why", any("left on its base" in x for x in body.get("routed", [])), body)

print(f"\n{'OK' if not failures else 'FAILED'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
