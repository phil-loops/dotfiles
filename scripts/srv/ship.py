# srv/ship.py — "ready to ship": one verb that makes a whole forest pushable.
# Fetches origin/main, CONTRACTS already-merged members (drop + rewire, sync's
# recipe), RESTACKS every survivor bottom-up onto fresh main — trees welcome,
# this is /stage's chain walk generalized over parent depth — then reports the
# push order. It never moves the main checkout (that's /stage) and never preps
# or pushes: the outgoing commit stays editable at the node's prep/push buttons.
#
#   POST /ship {project, dryRun?} — dryRun reports the plan without moving anything.
#
# Guards mirror /stage: an open PR on any member refuses (pushed history is never
# rewritten), a dirty worktree holding a member refuses. A conflict mid-walk
# restores every branch to its pre-ship snapshot — all-or-nothing.
import json

from . import ctx, sync
from .stage import _parent, _worktrees, _dirty


def _members(project):
    """The forest's live branches: config seeds ∪ .project tags, expanded along
    parent edges (a child follows its forest even when its own tag rotted)."""
    seeds = set(ctx.run(["git", "config", "--get-all", f"stack-project.{project}.branch"]).stdout.split())
    for line in ctx.run(["git", "config", "--get-regexp", r"^stack-branch\..*\.project$"]).stdout.splitlines():
        key, _, val = line.partition(" ")
        if val.strip() == project:
            seeds.add(key[len("stack-branch."):-len(".project")])
    parents = {}
    for line in ctx.run(["git", "config", "--get-regexp", r"^stack-branch\..*\.parent$"]).stdout.splitlines():
        key, _, val = line.partition(" ")
        parents[key[len("stack-branch."):-len(".parent")]] = val.strip()
    grew = True
    while grew:
        grew = False
        for b, p in parents.items():
            if p in seeds and b not in seeds:
                seeds.add(b)
                grew = True
    return [b for b in seeds
            if ctx.run(["git", "rev-parse", "--verify", "-q", f"refs/heads/{b}"]).returncode == 0]


def _topo(members):
    """Members ordered parents-before-children (depth along parent links, roots first)."""
    ms = set(members)
    def depth(b, seen=()):
        p = _parent(b)
        if p not in ms or b in seen:
            return 0
        return 1 + depth(p, (*seen, b))
    return sorted(members, key=lambda b: (depth(b), b))


def _rebase_delete_wins(scratch, onto, cut, b):
    """Rebase b (--onto onto, replay from cut), auto-resolving ONLY modify/delete conflicts
    where the branch deletes the file: a removal branch exists to drop that file, so the
    base's edits to a doomed file are moot — the deletion wins. Any other conflict class is
    left parked (rebase in progress) for the caller to abort + restore.
    Returns True if it landed (clean or delete-resolved), False on a real conflict."""
    r = ctx.run(["git", "-C", scratch, "rebase", "--onto", onto, cut, b])
    while r.returncode != 0:
        unmerged = [ln for ln in ctx.run(["git", "-C", scratch, "status", "--porcelain"]).stdout.splitlines()
                    if ln[:2] in ("UD", "DU", "UU", "AA", "DD", "AU", "UA")]
        # UD = ours (the base) modified, theirs (this branch's commit) deleted → delete wins.
        if not unmerged or any(ln[:2] != "UD" for ln in unmerged):
            return False
        for ln in unmerged:
            # bail if a removal can't be staged, so a stuck resolution can't spin forever
            if ctx.run(["git", "-C", scratch, "rm", "-q", "--", ln[3:]]).returncode != 0:
                return False
        r = ctx.run(["git", "-c", "core.editor=true", "-C", scratch, "rebase", "--continue"])
    return True


def _fork_cut(branch, parent, parent_sha):
    """Where BRANCH's own commits start — the replay cut for `rebase --onto <parent> <cut>`.
    For a seated branch that's the parent's old tip. A DRIFTED branch doesn't descend from that
    tip (the parent was rewritten under it, or it forked elsewhere), and cutting there replays
    the parent's superseded commits too — a rewrite leaves them not patch-identical, so they
    collide with the new parent instead of deduping away. --fork-point reads the parent's reflog
    for the tip the branch really forked from. None = the reflog can't reach it; the caller
    refuses rather than guess (plain merge-base would back up to main and replay everything)."""
    if ctx.run(["git", "merge-base", "--is-ancestor", parent_sha, branch]).returncode == 0:
        return parent_sha
    return ctx.run(["git", "merge-base", "--fork-point", parent, branch]).stdout.strip() or None


def _drifted(branch, parent):
    return ctx.run(["git", "merge-base", "--is-ancestor", parent, branch]).returncode != 0


def ship(req, raw):
    d = json.loads(raw or "{}")
    project = d.get("project", "")
    dry = bool(d.get("dryRun"))
    ctx.run(["git", "fetch", "origin", "main"])

    members = _topo(_members(project))
    if not members:
        return req._send(400, json.dumps({"ok": False, "err": "no live branches in this forest"}))

    published = sync._open_pr_heads(fresh=True)
    prd = [b for b in members if b in published]
    if prd:
        return req._send(200, json.dumps({"ok": False, "err": f"{', '.join(prd)} has an open PR — ship rebases, and pushed history is never rewritten"}))

    # A ghost is exactly what the map's drop pill calls droppable: merged — GitHub-authoritative
    # when the branch has a PR — AND contractable. The local exit-20 probe alone missed a node
    # whose work had landed but whose branch was already restacked onto that landing, so ship
    # walked past it reporting "already ready" while the dead node sat in the graph forever.
    # Merged-ness is what keeps this off a branch you just forked (also empty, never merged).
    pr_map = sync._pr_state_map()
    health = {b: sync._node_health(b, pr_map.get(b)) for b in members}
    ghosts = [b for b in members if health[b]["merged"] and health[b]["contractable"]]
    wts = _worktrees()
    squatters = [(p, b) for p, b in wts if b in members]
    dirty_squat = [p for p, b in squatters if b not in ghosts and _dirty(p)]
    if dirty_squat:
        return req._send(200, json.dumps({"ok": False, "err": f"worktree {dirty_squat[0]} holds a forest branch with uncommitted changes"}))

    survivors = [b for b in members if b not in ghosts]
    behind = max((int(ctx.run(["git", "rev-list", "--count", f"{b}..origin/main"]).stdout.strip() or "0")
                  for b in survivors), default=0)
    sset = set(survivors)
    drifted = [b for b in survivors if _parent(b) in sset and _drifted(b, _parent(b))]
    plan = {"ok": True, "project": project, "ghosts": ghosts, "members": survivors, "behind": behind,
            "drifted": drifted, "alreadyReady": not ghosts and behind == 0}
    if dry:
        return req._send(200, json.dumps(plan))

    contracted = []
    for g in ghosts:
        kids, deps, parent = sync._contract(g)
        contracted.append({"branch": g, "children": kids, "deps": deps, "parent": parent})
    survivors = _topo([b for b in _members(project) if b in survivors])

    moved = []
    if behind > 0 or contracted:
        ms = set(survivors)
        snapshots = {b: ctx.run(["git", "rev-parse", b]).stdout.strip() for b in survivors}
        # Every cut up front, off the pre-walk SHAs: a drifted node whose fork is unrecoverable
        # is refused BEFORE anything moves, instead of detonating as a conflict mid-walk.
        cuts = {}
        for b in survivors:
            p = _parent(b)
            cuts[b] = (_fork_cut(b, p, snapshots[p]) if p in ms
                       else ctx.run(["git", "merge-base", b, "origin/main"]).stdout.strip() or None)
        unseatable = [b for b in survivors if not cuts[b]]
        if unseatable:
            return req._send(200, json.dumps({
                "ok": False, "unseatable": unseatable,
                "err": f"{unseatable[0]} sits off its parent and its fork point is unrecoverable "
                       "(no reflog) — reseat it by hand, then ship again. Nothing was moved.",
            }))
        detached = []
        for p, b in _worktrees():
            if b in ms and not _dirty(p) and ctx.run(["git", "-C", p, "checkout", "--detach"]).returncode == 0:
                detached.append((p, b))
        scratch = "/tmp/viewer-ship-scratch"
        ctx.run(["git", "worktree", "remove", "--force", scratch])
        r = ctx.run(["git", "worktree", "add", "--detach", scratch, "origin/main"])
        if r.returncode != 0:
            return req._send(200, json.dumps({"ok": False, "err": f"couldn't make a scratch worktree: {r.stderr.strip()}"}))
        try:
            for b in survivors:
                p = _parent(b)
                onto = p if p in ms else "origin/main"
                cut = cuts[b]
                if ctx.run(["git", "rev-parse", b]).stdout.strip() == cut:
                    continue  # empty branch (all its commits were the cut) — nothing to replay
                if not _rebase_delete_wins(scratch, onto, cut, b):
                    ctx.run(["git", "-C", scratch, "rebase", "--abort"])
                    for rb, sha in snapshots.items():
                        ctx.run(["git", "branch", "-f", rb, sha])
                    return req._send(200, json.dumps({
                        "ok": False, "conflict": b,
                        "err": f"rebase of {b} hit a real conflict (a delete/modify would auto-resolve) "
                               "— every branch restored to where it was",
                    }))
                moved.append(b)
        finally:
            ctx.run(["git", "worktree", "remove", "--force", scratch])
            # reseat every worktree we detached — a failed ship that leaves your checkouts on a
            # detached HEAD is a half-done ship, however intact the refs are.
            for p, b in detached:
                ctx.run(["git", "-C", p, "checkout", b])

    if not any(b == "main" for _, b in _worktrees()):
        ctx.run(["git", "branch", "-f", "main", "origin/main"])

    order = []
    for b in survivors:
        p = _parent(b)
        commits = int(ctx.run(["git", "rev-list", "--count", f"{p if p in set(survivors) else 'origin/main'}..{b}"]).stdout.strip() or "0")
        up = ctx.run(["git", "rev-parse", "--verify", "-q", f"{b}@{{upstream}}"]).stdout.strip()
        order.append({"branch": b, "commits": commits,
                      "unpushed": not up or up != ctx.run(["git", "rev-parse", b]).stdout.strip()})
    req._send(200, json.dumps({**plan, "alreadyReady": not moved and not contracted,
                               "contracted": contracted, "moved": moved, "order": order}))
