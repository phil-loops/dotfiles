#!/usr/bin/env python3
"""A press acts on the commit Phil saw (srv/seen.py): /push-origin and /gates-waive name the tip that
was on screen, refuse one that moved — saying what arrived, so the next press is made having seen it —
and refuse a request that names none. Temp repo; the push itself is a stand-in, so nothing is pushed."""
import testenv  # noqa: F401,E402 — git here ignores the machine's config (testenv.py)
import json
import os
import shutil
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
repo = os.path.join(tempfile.mkdtemp(prefix="seen-"), "r")
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True, env=env)
os.chdir(repo)
ctx.run = lambda argv, **kw: subprocess.run(argv, capture_output=True, text=True, env=env, cwd=kw.get("cwd", repo))
ctx.CWD = ctx.MAIN_WT = repo
ctx.log = lambda line: None
from srv import push, review, seen, stackcfg, verdicts  # noqa: E402

pushed = []
push.push_now = lambda branch, stay=False, tip=None: pushed.append((branch, tip)) or {"ok": True}


def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True, env=env, check=True).stdout.strip()


def commit(msg):
    with open("f.txt", "a") as f:
        f.write(msg + "\n")
    git("add", "f.txt")
    git("commit", "-q", "-m", msg)
    return git("rev-parse", "HEAD")


class Req:
    def _send(self, code, body, *a):
        self.code, self.body = code, json.loads(body)


def post(handler, body):
    r = Req()
    handler(r, json.dumps(body))
    return r


commit("root")
git("checkout", "-q", "-b", "b")
saw = commit("the commit Phil saw")

r = post(push.push_origin, {"branch": "b"})
check("a push naming no commit is refused", r.code == 400 and "expectTip" in r.body["err"] and not pushed, r.body)
r = post(push.push_origin, {"branch": "b", "expectTip": saw})
check("a push for the commit on screen goes through, pinned to it", r.body.get("ok") and pushed == [("b", saw)], (r.body, pushed))

pushed.clear()
commit("fix the import")
commit("tidy")
r = post(push.push_origin, {"branch": "b", "expectTip": saw})
check("a branch that moved since is refused and nothing goes out", r.body.get("moved") and not pushed, r.body)
check("…naming what arrived, oldest first", [c["subject"] for c in r.body.get("commits", [])] == ["fix the import", "tidy"], r.body)
check("…in one line", "fix the import +1 more" in r.body.get("err", ""), r.body.get("err"))
check("…with the tip it holds now, for the next press", r.body.get("now") == git("rev-parse", "b"), r.body)

git("reset", "-q", "--hard", "HEAD~3")
rewritten = commit("a different history")
r = post(push.push_origin, {"branch": "b", "expectTip": saw})
check("a rewritten branch says rewritten", r.body.get("moved") and r.body.get("rewritten") and "rewritten" in r.body["err"], r.body)

stackcfg.set_key = lambda b, k, v: git("config", f"branch.{b}.stack-{k}", v)
r = post(verdicts.waive, {"branch": "b", "expectTip": saw})
check("a waiver for a commit no longer there is refused", r.body.get("moved") and not git("config", "--default", "", "branch.b.stack-gates-waived-tree"), r.body)
r = post(verdicts.waive, {"branch": "b"})
check("a waiver naming no commit is refused", r.code == 400, r.body)
r = post(verdicts.waive, {"branch": "b", "expectTip": rewritten})
check("a waiver for the commit on screen records that commit's tree", r.body.get("ok") and git("config", "branch.b.stack-gates-waived-tree") == git("rev-parse", "b^{tree}"), r.body)

published = rewritten
git("update-ref", "refs/remotes/origin/b", published)
observed = commit("outgoing")
latest = commit("another pane's commit")
ctx.SCRIPTS = HERE
before = (git("show-ref"), git("write-tree"), open("f.txt").read())
r = post(review.squash, {"branch": "b", "expectTip": observed})
check("stale squash names the new commit and preserves refs, index and files",
      r.code == 409 and r.body["commits"][0]["subject"] == "another pane's commit"
      and before == (git("show-ref"), git("write-tree"), open("f.txt").read()), r.body)
r = post(review.squash, {"branch": "b", "expectTip": latest[:8]})
check("squash requires a full commit id", r.code == 400, r.body)
# Inject an ordinary concurrent ref update immediately before the CLI's final compare-and-swap.
race = git("commit-tree", latest + "^{tree}", "-p", latest, "-m", "arrived during squash")
real_git = shutil.which("git")
wrapper = os.path.join(repo, ".git", "test-bin")
os.mkdir(wrapper)
shim = os.path.join(wrapper, "git")
with open(shim, "w") as f:
    f.write(f'#!/bin/sh\nif test "$1" = update-ref && test "$2" = -m; then\n'
            f'  "{real_git}" update-ref refs/heads/b {race} {latest} || exit 1\nfi\nexec "{real_git}" "$@"\n')
os.chmod(shim, 0o755)
old_path = env["PATH"]
env["PATH"] = wrapper + os.pathsep + old_path
try:
    r = post(review.squash, {"branch": "b", "expectTip": latest})
finally:
    env["PATH"] = old_path
check("a commit racing the final reset survives with its index and files", r.code == 409 and r.body.get("moved")
      and git("rev-parse", "b") == race and git("write-tree") == before[1] and open("f.txt").read() == before[2], r.body)
latest = race
r = post(review.squash, {"branch": "b", "expectTip": latest})
check("a fresh squash preserves published history and leaves both outgoing changes unstaged",
      r.code == 200 and r.body.get("unstaged") and git("rev-parse", "b") == published
      and git("write-tree") == git("rev-parse", published + "^{tree}") and git("rev-parse", "ORIG_HEAD") == latest
      and open("f.txt").read() == before[2] and git("diff", "--name-only") == "f.txt", r.body)

with open("fold.txt", "w") as f:
    f.write("included by sync")
r = post(push.dirty_resolve, {"branch": "b", "action": "include"})
check("fold acknowledges the exact new commit and the tip it was built on",
      r.body.get("tip") == git("rev-parse", "HEAD") and r.body.get("parent") == published, r.body)

print(f"\n{'OK' if not failures else 'FAILED'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
