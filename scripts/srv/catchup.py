"""Catch a branch up to its parent, the whole chain at once (tooling-doctor A4, P7).

A stack falls behind from above: a grandparent gains a commit, and the child's own parent hasn't
moved, so nothing about the child looks off (2026-11-17: let-disable-take-a-suspicious-activity
moved, cite-the-openai-checks-activity sat off it, and record-the-banned-word-activity-first's push
was refused "history diverged" with no action on its page). catch_up(branch) walks the chain from
the top ancestor down to `branch`; each link off its parent's tip catches up before the next:

  unpublished (no origin copy)  rebased onto the parent's tip — local history is a draft
  published (origin has it)     a catch-up merge: one commit whose tree is the branch replayed on
                                the parent's tip and whose parents are origin's copy and the
                                parent's tip, with the branch's unpushed commits replayed on top
                                (_under_unpushed) — append-only, so a plain push fast-forwards
                                the PR and the PR's diff is its own change again (CLAUDE.md
                                *History*)

The new tree is computed by a guarded rebase on a DETACHED checkout, so no branch moves until its
result is known; each ref then moves by compare-and-swap. The first conflict stops the walk with
nothing half-done. Callers hold the forest lock (the /catch-up route does)."""
import hashlib
import json
import os
import re

from . import ctx, rebaseguard, repostate, seen, sync

TRUNKS = ("", "main", "master", "origin/main")


def _git(*a):
    return ctx.run(["git", *a])


def _sha(ref):
    return _git("rev-parse", "--verify", "-q", ref).stdout.strip()


def parent(b):
    return _git("config", f"branch.{b}.stack-parent").stdout.strip()


def chain(branch, parent_of=parent):
    """The stack from its top ancestor (the child of main) down to the branch."""
    out = []
    while branch not in TRUNKS and branch not in out:
        out.append(branch)
        branch = parent_of(branch)
    return list(reversed(out))


def chain_stamp(branch, snap, moved_tips=None):
    """Links, ancestor tips and origin copies. The leaf tip travels separately as expectTip."""
    tips = moved_tips or {}
    links = [(b, snap.branch_key(b, "parent"), tips.get(b, snap.local(b)) if b != branch else "", snap.remote(b))
             for b in chain(branch, lambda b: snap.branch_key(b, "parent"))]
    return hashlib.sha256(json.dumps(links).encode()).hexdigest()


def off_parent(b):
    p = parent(b)
    if p in TRUNKS or not _sha(f"refs/heads/{p}"):
        return False
    return _git("merge-base", "--is-ancestor", f"refs/heads/{p}", f"refs/heads/{b}").returncode != 0


_MOVER = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "stack-move-branch")


def _move(b, old, new):
    """Move refs/heads/<b> old → new by compare-and-swap (stack-move-branch): a clean worktree
    holding it moves with it, a dirty one is named and nothing moves."""
    r = ctx.run([_MOVER, b, new, old])
    return "" if r.returncode == 0 else (r.stderr or f"{b} moved while catching up — retry").strip().replace("stack-move-branch: ", "")


def unpushed(b, tip=None, origin=None):
    """(own, merges) on `b`'s first-parent line past origin's copy, oldest first: its own unpushed
    commits, and the merges among them. ([], []) when origin has no copy or isn't under the tip."""
    o = _sha(f"refs/remotes/origin/{b}") if origin is None else origin
    tip = tip or _sha(f"refs/heads/{b}")
    if not o or not tip or o == tip or _git("merge-base", "--is-ancestor", o, tip).returncode != 0:
        return [], []
    rows = [ln.split() for ln in _git("rev-list", "--first-parent", "--reverse", "--parents", f"{o}..{tip}").stdout.splitlines()]
    return [r[0] for r in rows if len(r) == 2], [r[0] for r in rows if len(r) > 2]


def _pick(onto, c):
    """Cherry-pick `c` onto `onto` in the object store, its author and message kept; "" on conflict."""
    r = _git("merge-tree", "--write-tree", f"--merge-base={c}^", onto, c)
    tree = r.stdout.split("\n", 1)[0].strip()
    meta = _git("log", "-1", "--format=%an%x1f%ae%x1f%aI%x1f%B", c).stdout.split("\x1f", 3)
    if r.returncode != 0 or not tree or len(meta) != 4:
        return ""
    sign = ["-S"] if _git("config", "--get", "commit.gpgsign").stdout.strip() == "true" else []
    return ctx.run(["env", f"GIT_AUTHOR_NAME={meta[0]}", f"GIT_AUTHOR_EMAIL={meta[1]}", f"GIT_AUTHOR_DATE={meta[2]}",
                    "git", "commit-tree", *sign, tree, "-p", onto, "-m", meta[3].strip()]).stdout.strip()


def _under_unpushed(b, tip, second, tree, msg, caught_up, origin=None):
    """The catch-up for a published branch that is ahead of origin, in the one shape the push door
    takes (push.py `catchup`): a single merge, the oldest outgoing commit, its first parent
    origin's copy. A merge on the local tip sits on top of the unpushed commits, and a second one
    before a push makes two, so canopy's own catch-up built what its own door refused (2026-11-19,
    2026-11-23). Here the merge goes on origin's copy (its tree: caught_up(origin's copy)), earlier
    unpushed catch-ups of `second`'s line fold into it, and the branch's unpushed commits are
    replayed on top. The result must end on `tree`, the tree a merge on the local tip would have:
    only ancestry changes, never content. Returns the new tip, or "" when there is nothing
    unpushed or that tree can't be reached this way (an unpushed merge of something else, a
    replay that conflicts) — the caller then merges on the local tip, which loses nothing."""
    origin = _sha(f"refs/remotes/origin/{b}") if origin is None else origin
    own, merges = unpushed(b, tip, origin)
    if not own and not merges:
        return ""
    if any(_git("merge-base", "--is-ancestor", f"{m}^2", second).returncode != 0 for m in merges):
        ctx.log(f"catch-up: {b} has an unpushed merge of something other than its base — merging on its local tip")
        return ""
    under = caught_up(origin)
    new = _git("commit-tree", under, "-p", origin, "-p", second, "-m", msg).stdout.strip() if under else ""
    for c in own:
        new = new and _pick(new, c)
    if not new or _git("rev-parse", f"{new}^{{tree}}").stdout.strip() != tree:
        ctx.log(f"catch-up: {b}'s unpushed commits didn't replay onto a merge of origin's copy to the same tree — merging on its local tip")
        return ""
    return new


def _replayed(wt, rev, onto):
    """`rev`'s commits past its merge base with `onto`, rebased onto `onto` in the detached scratch
    checkout; the rebased tip, or "" on conflict. No branch moves."""
    cut = _git("merge-base", rev, onto).stdout.strip()
    _git("-C", wt, "checkout", "-q", "--detach", rev)
    r = rebaseguard.run(wt, ["--onto", onto, cut]) if cut else None
    if r is None or r.returncode != 0:
        _git("-C", wt, "checkout", "-q", "--detach", rev)
        return ""
    rebased = _git("-C", wt, "rev-parse", "HEAD").stdout.strip()
    _git("-C", wt, "checkout", "-q", "--detach")
    return rebased


def catch_up_one(b, wt=None):
    """(how, err): how is 'rebased' or 'merged'; err non-empty stops the walk. `wt` is the
    detached scratch checkout to compute in (default: the server's own)."""
    p = parent(b)
    tip, ptip = _sha(f"refs/heads/{b}"), _sha(f"refs/heads/{p}")
    how, new, err = _plan(b, p, tip, ptip, _sha(f"refs/remotes/origin/{b}"), wt)
    return how, err or _move(b, tip, new)


def _plan(b, p, tip, ptip, origin, wt):
    cut = _git("merge-base", tip, ptip).stdout.strip()
    if not (tip and ptip and cut):
        return "", "", f"couldn't resolve {b}'s parent {p}"
    wt = wt or sync._scratch_wt()
    state = rebaseguard.heal(wt)
    if state in ("person", "live"):
        return "", "", f"the scratch checkout {wt} has a rebase in progress — finish or abort it"
    rebased = _replayed(wt, tip, ptip)
    if not rebased:
        return "", "", f"{b} conflicts with {p}'s new commits — resolve it by hand (nothing was moved)"
    if not origin:
        return "rebased", rebased, ""
    tree = _git("rev-parse", f"{rebased}^{{tree}}").stdout.strip()
    msg = f"catch up to {p}\n\nVia: /catch-up (stack-review-server)"

    def caught_up(rev):
        r = _replayed(wt, rev, ptip)
        return r and _git("rev-parse", f"{r}^{{tree}}").stdout.strip()
    carrier = (_under_unpushed(b, tip, ptip, tree, msg, caught_up, origin)
               or ctx.run(["git", "commit-tree", tree, "-p", tip, "-p", ptip, "-m", msg]).stdout.strip())
    if not carrier:
        return "", "", f"couldn't build {b}'s catch-up merge"
    return "merged", carrier, ""


def land_plan(c, ptip, wt=None):
    """(how, new_tip, err) for a child whose parent (tip `ptip`) landed on main by a squash merge,
    computed without moving anything. git's merge base for the child and main is pre-squash, so
    the parent's change reads as made twice and conflicts with the child's own edits to it
    (#11659, #11674). The base that tells the truth is the parent tip the child was built on —
    merge-base(child, ptip): from there main's side is main's moves alone and the child's side
    is its own change (on #11674 this matched the hand resolution byte for byte).
      published    a catch-up merge (parents: the child, origin/main) whose tree is that merge
      unpublished  its own commits rebased onto origin/main from the same cut
    A conflict at that base is a real overlap with main: reported, never retried at another base."""
    tip, main = _sha(f"refs/heads/{c}"), _sha("refs/remotes/origin/main")
    base = _git("merge-base", tip, ptip).stdout.strip() if tip and ptip else ""
    if not (tip and main and base):
        return "", "", f"couldn't find where {c} sits on its landed parent"
    if _git("merge-base", "--is-ancestor", main, tip).returncode == 0:
        return "current", tip, ""
    if _sha(f"refs/remotes/origin/{c}"):
        r = _git("merge-tree", "--write-tree", f"--merge-base={base}", tip, main)
        tree = r.stdout.split("\n", 1)[0].strip()
        if r.returncode != 0 or not tree:
            return "", "", f"{c} overlaps main beyond its parent's landed change — a real conflict; resolve it by hand (nothing was moved)"
        msg = f"catch up to main\n\nits parent landed; merged against the tip {c} was built on ({base[:10]})"

        def caught_up(rev):
            b0 = _git("merge-base", rev, ptip).stdout.strip()
            r = _git("merge-tree", "--write-tree", f"--merge-base={b0}", rev, main) if b0 else None
            return r.stdout.split("\n", 1)[0].strip() if r is not None and r.returncode == 0 else ""
        carrier = (_under_unpushed(c, tip, main, tree, msg, caught_up)
                   or _git("commit-tree", tree, "-p", tip, "-p", main, "-m", msg).stdout.strip())
        return ("merged", carrier, "") if carrier else ("", "", f"couldn't build {c}'s catch-up merge")
    wt = wt or sync._scratch_wt()
    if rebaseguard.heal(wt) in ("person", "live"):
        return "", "", f"the scratch checkout {wt} has a rebase in progress — finish or abort it"
    _git("-C", wt, "checkout", "-q", "--detach", tip)
    r = rebaseguard.run(wt, ["--onto", main, base])
    if r.returncode != 0:
        _git("-C", wt, "checkout", "-q", "--detach", tip)
        return "", "", f"{c} conflicts with main beyond its parent's landed change — resolve it by hand (nothing was moved)"
    rebased = _git("-C", wt, "rev-parse", "HEAD").stdout.strip()
    _git("-C", wt, "checkout", "-q", "--detach")
    return "rebased", rebased, ""


def catch_up(branch, wt=None, snap=None):
    """Walk the observed chain top-down, carrying each successful move into its child's plan."""
    observed = snap is not None
    snap = snap or repostate.read_now()
    moved, tips = [], {}
    for b in chain(branch, lambda name: snap.branch_key(name, "parent")):
        p, tip = snap.branch_key(b, "parent"), snap.local(b)
        ptip = tips.get(p, snap.local(p))
        if p in TRUNKS or not ptip or snap.is_ancestor(ptip, tip):
            continue
        how, new, err = _plan(b, p, tip, ptip, snap.remote(b), wt)
        if observed and not err:
            now = repostate.read_now()
            if now.local(branch) != snap.local(branch) or chain_stamp(branch, now) != chain_stamp(branch, snap, tips):
                repostate.invalidate()
                return {"ok": False, "moved": moved, "stale": True,
                        "err": f"{branch}'s chain changed during catch-up — try again on the refreshed branch"}
        err = err or _move(b, tip, new)
        if err:
            return {"ok": False, "moved": moved, "stopped": {"branch": b, "why": err}, "err": err}
        tips[b] = new
        moved.append({"branch": b, "how": how})
    return {"ok": True, "moved": moved}


def children(b):
    """Branches whose stack-parent is `b`."""
    out = _git("config", "--get-regexp", r"^branch\..*\.stack-parent$").stdout
    return sorted(k[len("branch."):-len(".stack-parent")] for k, _, v in
                  (ln.partition(" ") for ln in out.splitlines()) if v.strip() == b)


def carry(branch, push_one=None, wt=None):
    """A parent's push carries its children (tooling-doctor P7, A4): after `branch` went out, each
    child off its tip catches up — a published child by a catch-up merge then a plain push through
    push_one(child) → (ok, err), an unpublished one by a local rebase — and the walk goes on down.
    A published child with unpushed commits of its own catches up and stays local, its subtree too:
    the press was for the parent. push_one=None catches up locally only (an agent's reshape: Phil
    pushes).
    A stop (conflict, a dirty holder, a door that refuses) is reported for that child and its own
    children are left as they were; siblings still go. Callers hold the forest lock."""
    out = []
    for c in children(branch):
        if not off_parent(c):
            out += carry(c, push_one, wt)   # caught up already (an earlier press): its children may not be
            continue
        own = len(unpushed(c)[0])
        how, err = catch_up_one(c, wt)
        rec = {"branch": c, "how": how}
        if err:
            out.append({**rec, "err": err})
            continue
        if how == "merged" and push_one and own:
            # the press was for the parent: the child's own unpushed commits wait for their own,
            # and nothing below it can go out before it does
            out.append({**rec, "unpushed": own})
            out += carry(c, None, wt)
            continue
        if how == "merged" and push_one:
            ok, perr = push_one(c)
            rec["pushed"] = ok
            if not ok:
                out.append({**rec, "err": perr or f"{c} didn't push"})
                continue
        out.append(rec)
        out += carry(c, push_one, wt)
    return out


def owes(branch):
    """The highest link in `branch`'s chain that is off its parent's tip, or "" — what the page
    names as the catch-up the branch owes (its own parent may not have moved at all)."""
    return next((b for b in chain(branch) if off_parent(b)), "")


def post(req, raw):
    d = json.loads(raw or "{}")
    b, stamp, tip = d.get("branch"), d.get("expectChain"), d.get("expectTip")
    if not isinstance(b, str) or not b or not isinstance(stamp, str) or not re.fullmatch("[0-9a-f]{64}", stamp) or not seen.full_tip(tip):
        return req._send(400, json.dumps({"ok": False, "err": "refresh the branch to catch up the chain you saw"}))
    snap = repostate.read_now()
    if snap.local(b) != tip:
        repostate.invalidate()
        why = seen.moved(b, tip) or {"ok": False, "err": f"{b} moved — refresh the branch"}
        return req._send(409, json.dumps({**why, "stale": True}))
    if chain_stamp(b, snap) != stamp:
        repostate.invalidate()
        return req._send(409, json.dumps({"ok": False, "stale": True, "err": f"{b}'s chain changed since you looked — try again on the refreshed branch"}))
    result = catch_up(b, snap=snap)
    req._send(409 if result.get("stale") else 200, json.dumps(result))
