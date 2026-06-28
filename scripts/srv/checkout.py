# srv/checkout.py — move the user's primary checkout onto a branch + worktree prep.
#   GET  /head      the branch the main checkout currently points at (jump-to-checkout)
#   POST /prepare   prefetch: build a branch's worktree in the background
#   POST /checkout  move the main worktree onto a branch (frees another worktree on --force)
#   POST /worktree  reveal a branch's worktree in Finder (materialise a scratch one if none)
import os
import json
import subprocess

from . import ctx


def _active_main_wt():
    # The PRIMARY worktree of the request's ACTIVE repo — git lists the main worktree first,
    # even when run from a linked one, and ctx.run's cwd is the pinned repo (the /<repo>/ path
    # prefix). NOT the global ctx.MAIN_WT, which is always the launched repo (loops) → a monotoad
    # checkout-here would otherwise run `git -C <loops> checkout <monotoad-branch>` and fail.
    for line in ctx.run(["git", "worktree", "list", "--porcelain"]).stdout.splitlines():
        if line.startswith("worktree "):
            return line[len("worktree "):]
    return ctx.MAIN_WT


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
        {"branch": ctx.run(["git", "-C", _active_main_wt(), "rev-parse", "--abbrev-ref", "HEAD"]).stdout.strip()}))


def prepare(req, raw):
    d = json.loads(raw or "{}")
    subprocess.Popen([os.path.join(ctx.SCRIPTS, "stack-open"), "--prepare", d.get("branch", "")],
                     cwd=ctx.CWD, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    req._send(200, '{"ok":true}')


def worktree(req, raw):
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    if not branch:
        req._send(400, json.dumps({"ok": False, "err": "no branch"}))
        return
    # --path resolves the branch's real worktree, or materialises (and prints) a scratch one —
    # so a watched/PR branch checked out nowhere still gets a tree to open. Synchronous.
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-open"), "--path", branch])
    path = (r.stdout or "").strip()
    if r.returncode != 0 or not path:
        req._send(500, json.dumps({"ok": False, "err": (r.stderr or "could not resolve a worktree").strip()}))
        return
    subprocess.Popen(["open", path])  # reveal in Finder (macOS); fire-and-forget
    req._send(200, json.dumps({"ok": True, "path": path}))


def move(req, raw):
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    main_wt = _active_main_wt()
    wt = _worktree_of(branch)
    if wt and os.path.realpath(wt) != os.path.realpath(main_wt):
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
    r = ctx.run(["git", "-C", main_wt, "checkout", branch])
    req._send(200 if r.returncode == 0 else 500,
              json.dumps({"ok": r.returncode == 0, "out": r.stdout, "err": r.stderr}))
