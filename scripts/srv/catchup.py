"""Catch a branch up to its parent, the whole chain at once (tooling-doctor A4, P7).

A stack falls behind from above: a grandparent gains a commit, and the child's own parent hasn't
moved, so nothing about the child looks off (2026-11-17: let-disable-take-a-suspicious-activity
moved, cite-the-openai-checks-activity sat off it, and record-the-banned-word-activity-first's push
was refused "history diverged" with no action on its page). catch_up(branch) walks the chain from
the top ancestor down to `branch`; each link off its parent's tip catches up before the next:

  unpublished (no origin copy)  rebased onto the parent's tip — local history is a draft
  published (origin has it)     a catch-up merge: one commit whose tree is the branch replayed on
                                the parent's tip and whose parents are the branch's tip and the
                                parent's tip — append-only, so a plain push fast-forwards the PR
                                and the PR's diff is its own change again (CLAUDE.md *History*)

The new tree is computed by a guarded rebase on a DETACHED checkout, so no branch moves until its
result is known; each ref then moves by compare-and-swap. The first conflict stops the walk with
nothing half-done. Callers hold the forest lock (the /catch-up route does)."""
import os

from . import ctx, rebaseguard, sync

TRUNKS = ("", "main", "master", "origin/main")


def _git(*a):
    return ctx.run(["git", *a])


def _sha(ref):
    return _git("rev-parse", "--verify", "-q", ref).stdout.strip()


def parent(b):
    return _git("config", f"branch.{b}.stack-parent").stdout.strip()


def chain(branch):
    """The stack from its top ancestor (the child of main) down to `branch`."""
    out, cur = [], branch
    while cur and cur not in out and parent(cur) not in TRUNKS and len(out) < 30:
        out.append(cur)
        cur = parent(cur)
    if cur and cur not in out:
        out.append(cur)
    return list(reversed(out))


def off_parent(b):
    p = parent(b)
    if p in TRUNKS or not _sha(f"refs/heads/{p}"):
        return False
    return _git("merge-base", "--is-ancestor", f"refs/heads/{p}", f"refs/heads/{b}").returncode != 0


def _move(b, old, new):
    """Move refs/heads/<b> old → new: reset a clean holding worktree in place, else CAS the ref."""
    holder = sync._worktree_of(b)
    if holder:
        if not sync._clean(holder):
            return f"{holder} holds {b} with uncommitted changes — commit or stash first"
        if _git("-C", holder, "rev-parse", "HEAD").stdout.strip() != old:
            return f"{b} moved while catching up — retry"
        r = _git("-C", holder, "reset", "--hard", new)
    else:
        r = _git("update-ref", f"refs/heads/{b}", new, old)
    return "" if r.returncode == 0 else f"{b} moved while catching up — retry"


def catch_up_one(b):
    """(how, err): how is 'rebased' or 'merged'; err non-empty stops the walk."""
    p = parent(b)
    tip, ptip = _sha(f"refs/heads/{b}"), _sha(f"refs/heads/{p}")
    cut = _git("merge-base", tip, ptip).stdout.strip()
    if not (tip and ptip and cut):
        return "", f"couldn't resolve {b}'s parent {p}"
    wt = sync._scratch_wt()
    state = rebaseguard.heal(wt)
    if state in ("person", "live"):
        return "", f"the scratch checkout {wt} has a rebase in progress — finish or abort it"
    _git("-C", wt, "checkout", "-q", "--detach", tip)
    r = rebaseguard.run(wt, ["--onto", ptip, cut])
    if r.returncode != 0:
        _git("-C", wt, "checkout", "-q", "--detach", tip)
        return "", f"{b} conflicts with {p}'s new commits — resolve it by hand (nothing was moved)"
    rebased = _git("-C", wt, "rev-parse", "HEAD").stdout.strip()
    _git("-C", wt, "checkout", "-q", "--detach")
    published = bool(_sha(f"refs/remotes/origin/{b}"))
    if not published:
        err = _move(b, tip, rebased)
        return ("rebased", err)
    tree = _git("rev-parse", f"{rebased}^{{tree}}").stdout.strip()
    msg = f"catch up to {p}\n\nVia: /catch-up (stack-review-server)"
    carrier = ctx.run(["git", "commit-tree", tree, "-p", tip, "-p", ptip, "-m", msg]).stdout.strip()
    if not carrier:
        return "", f"couldn't build {b}'s catch-up merge"
    return ("merged", _move(b, tip, carrier))


def catch_up(branch):
    """Walk the chain top-down; returns {ok, moved: [{branch, how}], stopped?: {branch, why}}."""
    moved = []
    for b in chain(branch):
        if not off_parent(b):
            continue
        how, err = catch_up_one(b)
        if err:
            return {"ok": False, "moved": moved, "stopped": {"branch": b, "why": err}, "err": err}
        moved.append({"branch": b, "how": how})
    return {"ok": True, "moved": moved}


def owes(branch):
    """The highest link in `branch`'s chain that is off its parent's tip, or "" — what the page
    names as the catch-up the branch owes (its own parent may not have moved at all)."""
    return next((b for b in chain(branch) if off_parent(b)), "")


def post(req, raw):
    """POST /catch-up {branch} — catch the chain up to `branch` (routes.py holds the forest lock)."""
    import json
    try:
        b = (json.loads(raw or "{}") or {}).get("branch", "")
    except ValueError:
        b = ""
    if not b or not _sha(f"refs/heads/{b}"):
        return req._send(400, json.dumps({"ok": False, "err": f"no branch {b or '(none)'}"}))
    req._send(200, json.dumps(catch_up(b)))
