# srv/checkout.py — move the user's primary checkout onto a branch + worktree prep.
#   GET  /head      the branch the main checkout currently points at (jump-to-checkout)
#   POST /prepare   prefetch: build a branch's worktree in the background
#   POST /checkout  move the main worktree onto a branch (frees another worktree on --force)
#   POST /worktree  reveal a branch's worktree in Finder (materialise a scratch one if none)
import glob
import os
import json
import subprocess
import time

from . import ctx

_PRESENCE_DIR = os.path.expanduser("~/.claude/session-presence")


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


def _dirty_count(wt):
    r = ctx.run(["git", "-C", wt, "status", "--porcelain"])
    if r.returncode != 0:
        return -1   # unreadable tree reads as unsafe, never as clean
    return len([ln for ln in r.stdout.splitlines() if ln.strip()])


def _live_session_in(wt):
    # A live Claude session whose cwd is this worktree still owns its checkout — detaching
    # under it yanks the branch name out from under live work (the incident the 409 exists
    # to prevent). Presence records are hook-written; a dead pid means the record is stale.
    tgt = os.path.realpath(wt)
    for f in glob.glob(os.path.join(_PRESENCE_DIR, "*.json")):
        try:
            with open(f) as fh:
                d = json.load(fh)
            if os.path.realpath(d.get("cwd") or "") != tgt:
                continue
            os.kill(int(d["pid"]), 0)
        except (OSError, ValueError, KeyError, json.JSONDecodeError):
            continue
        return {
            "pane": d.get("tmux_pane") or "",
            "idleSeconds": max(0, int(time.time()) - int(d.get("last_active") or 0)),
        }
    return None


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
    freed = ""
    if wt and os.path.realpath(wt) != os.path.realpath(main_wt):
        # git can't move the main tree onto a branch another worktree already holds.
        if not d.get("force"):
            dirty = _dirty_count(wt)
            session = _live_session_in(wt)
            if dirty != 0 or session:
                # tell the client where it lives AND why it's held, so the force-confirm is informed
                req._send(409, json.dumps({
                    "ok": False, "err": "already open in worktree at " + wt,
                    "worktree": wt, "dirty": max(dirty, 0), "session": session,
                }))
                return
            # provably safe — clean tree, no live session — so freeing it IS the checkout,
            # not a decision worth a roundtrip. This was 1-in-4 checkouts (telemetry, 07-06+).
            freed = wt
        rd = ctx.run(["git", "-C", wt, "checkout", "--detach"])
        if rd.returncode != 0:
            req._send(500, json.dumps({"ok": False, "err": "could not free worktree: " + (rd.stderr or rd.stdout)}))
            return
    r = ctx.run(["git", "-C", main_wt, "checkout", branch])
    if r.returncode == 0:
        req._send(200, json.dumps({"ok": True, "worktree": main_wt, "out": r.stdout, "freed": freed}))
        return
    # no `worktree` on failure: the client reads that key as "held in another tree, offer to
    # free it", so echoing main_wt here masks a dirty-tree refusal as a held state (silent loop).
    req._send(500, json.dumps({"ok": False, "err": (r.stderr or r.stdout or "checkout failed").strip()}))
