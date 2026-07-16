# srv/stage.py — "stage for testing": restack a forest's chain forward onto fresh
# origin/main, then move the MAIN working tree onto the tip so the dev server
# serves the whole feature. One button for the motion Phil otherwise does by hand
# (rebase bottom-up in a scratch worktree, detach squatting worktrees, checkout).
#
#   POST /stage {project, dryRun?} — dryRun reports the plan without moving anything.
#
# Guards, all server-side: single-chain forests only, dirty main checkout refuses,
# any chain branch with an OPEN PR refuses (pushed history is never rewritten), a
# dirty squatting worktree refuses. A conflict mid-walk aborts and restores every
# branch to its pre-stage snapshot — all-or-nothing.
import json

from . import ctx, sync


def _parent(branch):
    return (ctx.run(["git", "config", f"branch.{branch}.stack-parent"]).stdout.strip()
            or ctx.run(["git", "config", f"stack-branch.{branch}.parent"]).stdout.strip() or "main")


def _chain(project):
    """Root→tip chain of the forest's live branches, or (None, why)."""
    out = ctx.run(["git", "config", "--get-all", f"stack-project.{project}.branch"]).stdout.split()
    live = [b for b in out
            if ctx.run(["git", "rev-parse", "--verify", "-q", f"refs/heads/{b}"]).returncode == 0]
    if not live:
        return None, "no live branches registered for this forest"
    parents = {b: _parent(b) for b in live}
    tips = [b for b in live if b not in set(parents.values())]
    if len(tips) != 1:
        return None, f"forest isn't a single chain ({len(tips)} tips) — stage handles a line for now"
    chain = [tips[0]]
    while parents.get(chain[-1]) in live:
        chain.append(parents[chain[-1]])
    chain.reverse()
    return chain, None


def _worktrees():
    """[(path, branch-or-None)], main working tree first (git's order)."""
    wts, path, br = [], None, None
    for ln in ctx.run(["git", "worktree", "list", "--porcelain"]).stdout.splitlines():
        if ln.startswith("worktree "):
            if path:
                wts.append((path, br))
            path, br = ln[len("worktree "):], None
        elif ln.startswith("branch refs/heads/"):
            br = ln[len("branch refs/heads/"):]
    if path:
        wts.append((path, br))
    return wts


def _dirty(path):
    # tracked changes only — untracked files don't block a checkout
    return bool(ctx.run(["git", "-C", path, "status", "--porcelain", "-uno"]).stdout.strip())


def stage(req, raw):
    d = json.loads(raw or "{}")
    project = d.get("project", "")
    dry = bool(d.get("dryRun"))
    chain, err = _chain(project)
    if err:
        return req._send(400 if "no live branches" in err else 200,
                         json.dumps({"ok": False, "err": err}))
    root_parent = _parent(chain[0])
    if root_parent not in ("main", "master"):
        return req._send(200, json.dumps({"ok": False, "err": f"chain roots off {root_parent}, not main — stage only handles main-rooted lines"}))

    wts = _worktrees()
    root, root_branch = wts[0]
    if _dirty(root):
        return req._send(200, json.dumps({"ok": False, "err": "your main checkout has uncommitted changes — commit or stash before staging"}))
    published = sync._open_pr_heads(fresh=True)
    prd = [b for b in chain if b in published]
    if prd:
        return req._send(200, json.dumps({"ok": False, "err": f"{', '.join(prd)} has an open PR — staging rebases, and pushed history is never rewritten"}))

    ctx.run(["git", "fetch", "origin", "main"])
    tip = chain[-1]
    behind = int(ctx.run(["git", "rev-list", "--count", f"{tip}..origin/main"]).stdout.strip() or "0")
    squatters = [(p, b) for p, b in wts[1:] if b in chain]
    dirty_squat = [p for p, _ in squatters if _dirty(p)]
    if dirty_squat:
        return req._send(200, json.dumps({"ok": False, "err": f"worktree {dirty_squat[0]} holds a chain branch with uncommitted changes"}))

    plan = {
        "ok": True, "project": project, "chain": chain, "tip": tip, "behind": behind,
        "rootBranch": root_branch, "detach": [p for p, _ in squatters],
        "alreadyStaged": behind == 0 and root_branch == tip,
    }
    if dry:
        return req._send(200, json.dumps(plan))
    if plan["alreadyStaged"]:
        return req._send(200, json.dumps({**plan, "moved": [], "checkedOut": True}))

    snapshots = {b: ctx.run(["git", "rev-parse", b]).stdout.strip() for b in chain}
    if root_branch in chain:
        ctx.run(["git", "-C", root, "checkout", "--detach"])
    for p, _ in squatters:
        ctx.run(["git", "-C", p, "checkout", "--detach"])

    moved = []
    if behind > 0:
        scratch = "/tmp/viewer-stage-scratch"
        ctx.run(["git", "worktree", "remove", "--force", scratch])
        r = ctx.run(["git", "worktree", "add", "--detach", scratch, "origin/main"])
        if r.returncode != 0:
            return req._send(200, json.dumps({"ok": False, "err": f"couldn't make a scratch worktree: {r.stderr.strip()}"}))
        try:
            new_base = "origin/main"
            for i, b in enumerate(chain):
                cut = (ctx.run(["git", "merge-base", b, "origin/main"]).stdout.strip()
                       if i == 0 else snapshots[chain[i - 1]])
                r = ctx.run(["git", "-C", scratch, "rebase", "--onto", new_base, cut, b])
                if r.returncode != 0:
                    ctx.run(["git", "-C", scratch, "rebase", "--abort"])
                    for rb, sha in snapshots.items():
                        ctx.run(["git", "branch", "-f", rb, sha])
                    if root_branch in chain:
                        ctx.run(["git", "-C", root, "checkout", root_branch])
                    return req._send(200, json.dumps({
                        "ok": False, "conflict": b,
                        "err": f"rebase of {b} hit a conflict — everything restored to where it was",
                    }))
                moved.append(b)
                new_base = b
        finally:
            ctx.run(["git", "worktree", "remove", "--force", scratch])

    r = ctx.run(["git", "-C", root, "checkout", tip])
    if r.returncode != 0:
        return req._send(200, json.dumps({"ok": False, "err": f"restack done but checkout refused: {r.stderr.strip()}"}))
    req._send(200, json.dumps({**plan, "moved": moved, "checkedOut": True, "alreadyStaged": False}))
