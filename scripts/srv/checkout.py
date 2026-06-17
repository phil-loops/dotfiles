# srv/checkout.py — move the user's primary checkout onto a branch + worktree prep.
#   GET  /head      the branch the main checkout currently points at (jump-to-checkout)
#   POST /prepare   prefetch: build a branch's worktree in the background
#   POST /checkout  move the main worktree onto a branch (frees another worktree on --force)
import os
import json
import subprocess

from . import ctx


def _worktree_of(branch):   # path of the worktree currently holding `branch`, or ""
    if not branch:
        return ""
    path = ""
    for line in ctx.run(["git", "worktree", "list", "--porcelain"]).stdout.splitlines():
        if line.startswith("worktree "):
            path = line[len("worktree "):]
        elif line == "branch refs/heads/" + branch:
            return path
    return ""


def head(req):
    req._send(200, json.dumps(
        {"branch": ctx.run(["git", "-C", ctx.MAIN_WT, "rev-parse", "--abbrev-ref", "HEAD"]).stdout.strip()}))


def prepare(req, raw):
    d = json.loads(raw or "{}")
    subprocess.Popen([os.path.join(ctx.SCRIPTS, "stack-open"), "--prepare", d.get("branch", "")],
                     cwd=ctx.CWD, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    req._send(200, '{"ok":true}')


def move(req, raw):
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    wt = _worktree_of(branch)
    if wt and os.path.realpath(wt) != os.path.realpath(ctx.MAIN_WT):
        # git can't move the main tree onto a branch another worktree already holds.
        if not d.get("force"):
            # tell the client where it lives so it can offer to free it
            req._send(409, json.dumps({"ok": False, "err": "already open in worktree at " + wt, "worktree": wt}))
            return
        # force: detach that worktree's HEAD (keeps its commits, releases the branch name), then checkout here
        rd = ctx.run(["git", "-C", wt, "checkout", "--detach"])
        if rd.returncode != 0:
            req._send(500, json.dumps({"ok": False, "err": "could not free worktree: " + (rd.stderr or rd.stdout)}))
            return
    r = ctx.run(["git", "-C", ctx.MAIN_WT, "checkout", branch])
    req._send(200 if r.returncode == 0 else 500,
              json.dumps({"ok": r.returncode == 0, "out": r.stdout, "err": r.stderr}))
