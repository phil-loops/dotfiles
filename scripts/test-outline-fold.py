#!/usr/bin/env python3
"""srv/outline.py's fold: a commit absorbed into the one below it — one commit with the upper's
tree, the lower's author and both messages, the commits above rebuilt on it, the tip's tree
unchanged (the gates verdict stands), and the same journal entry undone by /outline-undo."""
import testenv  # noqa: F401,E402 — git here ignores the machine's config (testenv.py)
import json
import os
import subprocess
import sys
import tempfile
from unittest.mock import patch

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


env = {**os.environ, "GIT_AUTHOR_NAME": "lower", "GIT_AUTHOR_EMAIL": "l@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
for k in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"):
    env.pop(k, None)
root = tempfile.mkdtemp(prefix="outline-fold-")
origin, repo = os.path.join(root, "o.git"), os.path.join(root, "r")
subprocess.run(["git", "init", "-q", "--bare", origin], check=True)
subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)


def git(*a, **kw):
    e = dict(env, **kw.pop("env", {}))
    return subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, env=e, check=True).stdout.strip()


def commit(name, msg, author="lower"):
    with open(os.path.join(repo, name), "w") as f:
        f.write(name + "\n")
    git("add", name)
    git("commit", "-q", "-m", msg, env={"GIT_AUTHOR_NAME": author})
    return git("rev-parse", "HEAD")


git("remote", "add", "origin", origin)
commit("base.txt", "base"); git("update-ref", "refs/remotes/origin/main", "main")
git("checkout", "-q", "-b", "feat")
c1 = commit("one.txt", "feat: one\n\nwhy one")
c2 = commit("two.txt", "add two", author="upper")
c3 = commit("three.txt", "add three")
git("config", "branch.feat.stack-parent", "main")
tip = c3

ctx.CWD = ctx.MAIN_WT = repo
ctx.SCRIPTS = HERE
ctx.run = lambda argv, **kw: subprocess.run(argv, cwd=repo, capture_output=True, text=True, env=env)
ctx.log = lambda *a, **k: None
from srv import outline, repostate, reviewdesk  # noqa: E402


class Req:
    def __init__(self):
        self.status, self.body = None, None

    def _send(self, status, body, *a):
        self.status, self.body = status, json.loads(body)


def post(fn, body):
    r = Req(); fn(r, json.dumps(body)); return r


r = post(outline.save, {"branch": "feat", "head": tip, "fold": [c2]})
journal = r.body.get("journal")
check("the fold lands", r.status == 200 and r.body.get("folded") == 1 and r.body.get("changed") == 0, r.body)
new_tip = git("rev-parse", "feat")
log = git("log", "--format=%H%x1f%an%x1f%B%x1e", "origin/main..feat").split("\x1e")
rows = [l.strip("\n").split("\x1f") for l in log if l.strip()]
check("two commits remain where there were three", len(rows) == 2, [x[2] for x in rows])
top, combined = rows[0], rows[1]
check("the combined commit keeps the lower's author and carries both messages",
      combined[1] == "lower" and combined[2].strip() == "feat: one\n\nwhy one\n\nadd two", combined)
check("…and the upper's tree (two.txt is in it)", "two.txt" in git("ls-tree", "--name-only", combined[0]) and "three.txt" not in git("ls-tree", "--name-only", combined[0]))
check("the commit above is rebuilt on it, unchanged", top[2].strip() == "add three" and git("rev-parse", f"{top[0]}^") == combined[0])
check("the tip's tree is the same, so a tree-keyed verdict stands", git("rev-parse", f"{new_tip}^{{tree}}") == git("rev-parse", f"{tip}^{{tree}}"))

later = post(outline.save, {"branch": "feat", "prTitle": "second window"}).body["journal"]
noop = post(outline.save, {"branch": "feat", "prTitle": "second window"})
check("an unchanged save returns no journal", noop.status == 200 and noop.body["journal"] is None)
for missing in (None, "", " ", 42):
    r = post(outline.undo, {"branch": "feat", "journal": missing})
    check("undo needs a journal id", r.status == 400 and outline._undoable("feat")["id"] == later, r.body)
r = post(outline.undo, {"branch": "feat", "journal": journal})
check("the first window cannot undo the second window's title or its own fold",
      r.status == 409 and git("rev-parse", "feat") == new_tip and git("config", "branch.feat.stack-pr-title") == "second window")
r = post(outline.undo, {"branch": "feat", "journal": later})
check("the second window restores just its title", r.status == 200 and r.body["restored"] == ["prTitle"] and r.body["newTip"] == new_tip)
r = post(outline.undo, {"branch": "feat", "journal": later})
check("replaying an undo cannot consume the earlier entry", r.status == 409 and outline._undoable("feat")["id"] == journal)
r = post(outline.undo, {"branch": "feat", "journal": journal})
check("undo puts the three commits back", r.status == 200 and git("rev-parse", "feat") == tip, (r.body, git("rev-parse", "feat")))

thread = {"node": "t", "comments": [{"url": "https://example.test/review/1"}]}
with patch.object(reviewdesk, "_pr_for", return_value={"number": 1, "threads": [thread]}), patch.object(reviewdesk, "waits_for", return_value=[]):
    def address(**args):
        return post(reviewdesk.address, {"branch": "feat", **args}).body

    first = address(thread="t", sha=tip, head=tip)
    addressed = first["newTip"]
    second = address(thread="t", sha=addressed, head=addressed)
    wrong_branch = post(reviewdesk.address, {"branch": "another-branch", "undo": first["key"]})
    check("a draft key cannot undo a fix on a different branch", not wrong_branch.body["ok"] and git("rev-parse", "feat") == addressed)
    check("taking back a duplicate trailer removes only its draft", address(undo=second["key"])["ok"] and git("rev-parse", "feat") == addressed)
    later = post(outline.save, {"branch": "feat", "prBody": "newer"}).body["journal"]
    stale = address(undo=first["key"])
    check("a stale trailer undo keeps the newer edit and its draft", not stale["ok"] and outline._undoable("feat")["id"] == later
          and git("rev-parse", "feat") == addressed and [i["key"] for i in reviewdesk._items()] == [first["key"]], stale)
    post(outline.undo, {"branch": "feat", "journal": later})
    check("undoing the declared fix restores its tip and removes its draft", address(undo=first["key"])["ok"]
          and git("rev-parse", "feat") == tip and not reviewdesk._items())
    check("a repeated trailer undo is refused", not address(undo=first["key"])["ok"])
    legacy = {"branch": "feat", "key": "older-draft", "state": "draft"}
    reviewdesk._save_items([legacy])
    check("an older draft without an undo receipt stays intact", not address(undo=legacy["key"])["ok"] and reviewdesk._items() == [legacy])

r = post(outline.save, {"branch": "feat", "head": tip, "fold": [c1]})
check("the first commit has nothing below it", r.status == 400 and "nothing below" in r.body["err"], r.body)
git("update-ref", "refs/remotes/origin/feat", "feat")
repostate.invalidate()
r = post(outline.save, {"branch": "feat", "head": tip, "fold": [c2]})
check("a pushed commit can't be folded", r.status == 409 and "on a remote" in r.body["err"], r.body)

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
