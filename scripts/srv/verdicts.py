# srv/verdicts.py — the review verdict and Phil's gates waiver: tree-keyed records that only the
# process that produced them writes. A session asks for a review; it never asserts one.
#
#   POST /review          {branch, depth?}  → spawn stack-review-run (a run, kind "review"); any caller
#   GET  /review-progress ?branch=          → the run's state; a finished run's verdict is recorded here
#   POST /gates-waive     {branch}          → Phil ships this exact tree without gates (Phil only)
#
# Records (branch.<b>.stack-*, via stackcfg):
#   review-flags-tree, review-flag (multivar), review-depth, review-run (the run id) — from a finished run
#   gates-waived-tree, gates-waived-by                                     — written from Phil's click
# Both die with the next edit: readers compare them to the branch's current tree. 2026-11-05: a session
# hand-wrote review-flags-tree on three trees nobody reviewed, and a dropped guard reached the PR.
import json
import os
import time
from urllib.parse import parse_qs

from . import actor, ctx, repostate, runs, stackcfg

REVIEW_RUNS_KEPT = 14 * 86_400
DEPTHS = ("light", "standard", "full")


def _tree(branch):
    return ctx.run(["git", "rev-parse", "--verify", "-q", f"refs/heads/{branch}^{{tree}}"]).stdout.strip()


def _key(branch):
    from . import push   # the gates' repo id: one per repo, not per worktree
    return push._gate_key(branch)


def review_run(branch):
    return runs.find("review", _key(branch)) if branch else None


def _verdict(run):
    try:
        with open(run.path("verdict.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _flag_line(f):
    where = f["file"] + (f":{f['line']}" if f.get("line") else "") if f.get("file") else ""
    tag = "" if f.get("verdict") == "CONFIRMED" else "(plausible) "
    return f"{where} — {tag}{f['summary']}" if where else f"{tag}{f['summary']}"


def harvest(branch):
    """Record a finished run's verdict if it reviewed the tree the branch has now — idempotent, so any
    reader may call it. Returns the verdict it recorded (or already had), else None."""
    run = review_run(branch)
    if not run or run.alive():
        return None
    v = _verdict(run)
    if not v or not v.get("ok") or v.get("tree") != run.meta.get("tree") or v["tree"] != _tree(branch):
        return None
    snap = repostate.snapshot()
    if snap.branch_key(branch, "review-flags-tree") == v["tree"] and snap.branch_key(branch, "review-run") == run.id:
        return v
    stackcfg.unset_all(branch, "review-flag")
    for f in v.get("findings") or ():
        stackcfg.add_key(branch, "review-flag", _flag_line(f))
    stackcfg.set_key(branch, "review-depth", v.get("depth", ""))
    stackcfg.set_key(branch, "review-run", run.id)
    stackcfg.set_key(branch, "review-flags-tree", v["tree"])   # last: the tree key is what readers trust
    return v


def review(req, raw):
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    depth = d.get("depth") or ""
    if depth and depth not in DEPTHS:
        return req._send(400, json.dumps({"ok": False, "err": f"depth is one of {', '.join(DEPTHS)}"}))
    tree = _tree(branch) if branch else ""
    if not tree:
        return req._send(404, json.dumps({"ok": False, "err": f"no branch {branch or '(none)'}"}))
    old = review_run(branch)
    if old and old.meta.get("tree") == tree and (not depth or old.meta.get("depth") == depth):
        if old.alive():
            return req._send(200, json.dumps({"ok": True, "started": True, "already": True}))
        if not d.get("force") and harvest(branch):
            return req._send(200, json.dumps({"ok": True, "cached": True}))
    if old and old.alive():
        return req._send(200, json.dumps({"ok": False, "err": "a review of an older tree is still running — try again when it ends"}))
    key = _key(branch)
    out = os.path.join(runs.dir_of("review", key), "verdict.json")
    cmd = [os.path.join(ctx.SCRIPTS, "stack-review-run"), "--branch", branch, "--out", out, "--repo", ctx.repo_cwd()]
    if depth:
        cmd += ["--depth", depth]
    try:
        runs.start("review", key, cmd, cwd=ctx.repo_cwd(),
                   meta={"branch": branch, "tree": tree, "depth": depth, "by": getattr(req, "_actor", "")})
    except runs.Busy:
        return req._send(200, json.dumps({"ok": False, "err": "a review is already running for this branch"}))
    runs.prune("review", REVIEW_RUNS_KEPT)
    req._send(200, json.dumps({"ok": True, "started": True}))


def review_progress(req, u):
    branch = (parse_qs(u.query).get("branch") or [""])[0]
    run = review_run(branch)
    if not run:
        return req._send(200, json.dumps({"running": False, "err": "no review run for this branch"}))
    running = run.alive()
    out = {"running": running, "elapsed": round(time.time() - run.started, 1), "tree": run.meta.get("tree"),
           "stale": run.meta.get("tree") != _tree(branch)}
    v = None if running else _verdict(run)
    if v:
        harvest(branch)
        repostate.invalidate()
        out["result"] = v
    elif not running:
        out["dead"] = True
    req._send(200, json.dumps(out))


def waived(branch, tree=None):
    """Who waived the gates for the branch's current tree, or None."""
    snap = repostate.snapshot()
    at = snap.branch_key(branch, "gates-waived-tree")
    if not at or at != (tree or snap.tree(branch)):
        return None
    return snap.branch_key(branch, "gates-waived-by") or "Phil"


def waive(req, raw):
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    if not actor.is_phil(req):
        return req._send(403, json.dumps({"ok": False, "err": "only Phil's click ships without gates"}))
    tree = _tree(branch) if branch else ""
    if not tree:
        return req._send(404, json.dumps({"ok": False, "err": f"no branch {branch or '(none)'}"}))
    stackcfg.set_key(branch, "gates-waived-by", "Phil · " + time.strftime("%Y-%m-%d %H:%M"))
    stackcfg.set_key(branch, "gates-waived-tree", tree)
    req._send(200, json.dumps({"ok": True, "tree": tree}))
