# srv/review.py — the review surface: the forest model, per-node file list + diffs,
# commit log, branch purpose, blessing, and the squash/prep-for-push actions.
#   GET  /model?branch=X    the forest model JSON (stack-forest), cached on model_sig
#   GET  /node?branch=X     a node's file list (stack-forest --node)
#   GET  /purpose?branch=X  branch purpose/thesis (read; ?generate=1 opts into token spend)
#   GET  /file?branch&path  a file's contents on a ref (git show)
#   GET  /commits?branch=X  this branch's own commits (parent..branch)
#   POST /bless {branch,file}    mark file(s) reviewed (stack-bless)
#   POST /purpose {branch,text}  save a thesis as the branch description
#   POST /squash {branch}        collapse parent..branch into unstaged working-tree changes
#   POST /prep {branch}          prep-for-push: squash unpushed → one, then oxfmt
import os
import json
from urllib.parse import parse_qs

from . import ctx

_mcache = {}  # (branch, model_sig) -> model json — recompute only when something changed


def model(req, u):
    branch = parse_qs(u.query).get("branch", [""])[0]
    ck = (branch, ctx.model_sig())
    if ck in _mcache:
        req._send(200, _mcache[ck])
        return
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-forest"), branch])
    if r.returncode != 0:
        req._send(500, json.dumps({"error": r.stderr}))
    else:
        out = _enrich(r.stdout, branch)
        _mcache.clear()
        _mcache[ck] = out
        req._send(200, out)


def _enrich(raw, branch):
    # graft what the forest views want without an N-fetch round trip:
    #   description    — the branch's one-line purpose (git branch description), per node
    #   mergeRank      — deterministic merge-order depth, per node (handy for layout/labels)
    #   mergeOrder     — the canonical total order as a flat array, top-level. Consume this
    #                    VERBATIM: sorting nodes by mergeRank client-side reintroduces drift
    #                    (the rank ties, and the tie-break is the stack-project DECLARED order,
    #                    which the nodes map does not preserve). The array bakes the tie-break in.
    # All from stack-merge-rank — the single topo authority shared with stack-pr-body.
    # Best-effort: malformed JSON or a missing field just passes through untouched.
    try:
        data = json.loads(raw)
    except ValueError:
        return raw
    ranks, order = {}, []
    rk = ctx.run([os.path.join(ctx.SCRIPTS, "stack-merge-rank"), branch])
    if rk.returncode == 0:
        try:
            mr = json.loads(rk.stdout) or {}
            ranks, order = mr.get("rank", {}), mr.get("order", [])
        except ValueError:
            pass
    for bid, meta in (data.get("nodes") or {}).items():
        if not isinstance(meta, dict):
            continue
        desc = ctx.run(["git", "config", f"branch.{bid}.description"]).stdout.strip()
        if desc:
            meta["description"] = desc
        if ctx.run(["git", "config", f"stack-branch.{bid}.ready"]).stdout.strip() == "true":
            meta["ready"] = True
        if bid in ranks:
            meta["mergeRank"] = ranks[bid]
    if order:
        data["mergeOrder"] = order
    return json.dumps(data)


def _is_convergence(branch, stdout):
    # A convergence node: a real fan-in branch (has `requires`) whose OWN contribution
    # (parent...node) is empty — it never merges, it converges several bases into one view.
    try:
        if (json.loads(stdout) or {}).get("files"):
            return False  # has its own contribution — an ordinary node, not a convergence
    except ValueError:
        return False
    return bool(ctx.run(["git", "config", "--get-all", f"stack-branch.{branch}.requires"]).stdout.strip())


def node(req, u):
    q = parse_qs(u.query)
    branch = q.get("branch", [""])[0]
    base = q.get("base", [""])[0]
    # the ghost ✦<project> node diffs main..refs/stack/<project>-integration — an ephemeral octopus
    # of the project's leaves. Branches move, so rebuild it on select before diffing; stack-forest
    # --node handles the raw ref + --base main exactly like a real node's parent..branch.
    if branch.startswith("refs/stack/") and branch.endswith("-integration"):
        project = branch[len("refs/stack/"):-len("-integration")]
        ctx.run([os.path.join(ctx.SCRIPTS, "stack-integrate"), project, "--check"])
        base = base or "main"
    args = [os.path.join(ctx.SCRIPTS, "stack-forest"), "--node", branch]
    if base:
        args += ["--base", base]
    r = ctx.run(args)
    # A convergence node renders blank otherwise (its own parent...node diff is empty). Diff it
    # against the base instead (base...node, base=main) so it shows the WHOLE assembled feature —
    # a "review it all at once" surface — rather than a navigable blank.
    if r.returncode == 0 and not base and _is_convergence(branch, r.stdout):
        r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-forest"), "--node", branch, "--base", "main"])
    req._send(200 if r.returncode == 0 else 500,
              r.stdout if r.returncode == 0 else json.dumps({"branch": branch, "files": []}))


def pr_body(req, u):
    # draft a GitHub PR description that frames the branch in its forest (what + where-it-fits).
    # Spends tokens (stack-pr-body → claude) — only ever hit from an explicit "draft PR" click.
    branch = parse_qs(u.query).get("branch", [""])[0]
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-pr-body"), branch])
    req._send(200 if r.returncode == 0 else 500,
              r.stdout if r.returncode == 0 else "_(draft failed — see server log)_",
              "text/plain; charset=utf-8")


def purpose_get(req, u):
    q = parse_qs(u.query)
    args = [os.path.join(ctx.SCRIPTS, "stack-purpose")]
    if q.get("generate", ["0"])[0] == "1":   # opt-in token spend, only on ask
        args.append("--generate")
    args.append(q.get("branch", [""])[0])
    r = ctx.run(args)
    req._send(200 if r.returncode == 0 else 500,
              r.stdout if r.returncode == 0 else json.dumps({"thesis": "", "enables": "", "source": "none"}))


def forest_purposes(req, u):
    # one shot for the Forests-row hover card: every member branch + its one-line purpose
    # (git branch description), so "what's going on in here" reads at a glance without N fetches.
    project = parse_qs(u.query).get("project", [""])[0]
    members = ctx.run(["git", "config", "--get-all", f"stack-project.{project}.branch"]).stdout.splitlines()
    out, seen = [], set()
    for b in (m.strip() for m in members):
        if not b or b in seen:
            continue
        seen.add(b)
        thesis = ctx.run(["git", "config", f"branch.{b}.description"]).stdout.strip()
        out.append({"branch": b, "thesis": thesis})
    req._send(200, json.dumps(out))


def file(req, u):
    q = parse_qs(u.query)
    branch, path = q.get("branch", [""])[0], q.get("path", [""])[0]
    r = ctx.run(["git", "show", f"{branch}:{path}"])
    req._send(200 if r.returncode == 0 else 404,
              r.stdout if r.returncode == 0 else "(file not found on this ref)",
              "text/plain; charset=utf-8")


def commits(req, u):
    branch = parse_qs(u.query).get("branch", [""])[0]
    parent = ctx.run(["git", "config", f"stack-branch.{branch}.parent"]).stdout.strip() or "main"
    fmt = "%h\x1f%s\x1f%an\x1f%ad"   # \x1f = unit-sep: safe field split (subjects can hold anything)
    out = ctx.run(["git", "log", f"{parent}..{branch}", f"--format={fmt}", "--date=short"]).stdout
    rows = []
    for ln in out.splitlines():
        p = ln.split("\x1f")
        if len(p) >= 2:
            rows.append({"sha": p[0], "subject": p[1],
                         "author": p[2] if len(p) > 2 else "", "date": p[3] if len(p) > 3 else ""})
    req._send(200, json.dumps(rows))


# --- POST ---

def bless(req, raw):
    d = json.loads(raw or "{}")
    args = [os.path.join(ctx.SCRIPTS, "stack-bless"), d.get("branch", "")]
    f = d.get("file")
    if f and f != ".":
        args += ["--file", f]
    if d.get("unbless"):
        args.append("--unbless")
    r = ctx.run(args)
    req._send(200 if r.returncode == 0 else 500,
              json.dumps({"ok": r.returncode == 0, "out": r.stdout, "err": r.stderr}))


def purpose_set(req, raw):
    d = json.loads(raw or "{}")
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-purpose"), "--set", d.get("text", ""), d.get("branch", "")])
    req._send(200 if r.returncode == 0 else 500, r.stdout if r.returncode == 0 else "{}")


def ready_set(req, raw):
    # Toggle the manual ready-to-PR flag (stack-branch.<b>.ready). Promotes the branch's
    # forest on Home and badges the node; purely Phil's signal, nothing reads it but the viewer.
    d = json.loads(raw or "{}")
    branch, ready = d.get("branch", ""), bool(d.get("ready"))
    key = f"stack-branch.{branch}.ready"
    if ready:
        ctx.run(["git", "config", key, "true"])
    else:
        ctx.run(["git", "config", "--unset", key])
    req._send(200, json.dumps({"ok": True, "branch": branch, "ready": ready}))


def squash(req, raw):
    d = json.loads(raw or "{}")
    # squash button → collapse parent..branch into UNSTAGED working-tree changes, no commit
    # (Phil writes the commit in GitHub Desktop). See stack-squash --unstage.
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-squash"), "--unstage", d.get("branch", "")])
    # stack-squash always prints a JSON report (on success AND handled failure)
    req._send(200 if r.returncode == 0 else 500,
              r.stdout or json.dumps({"ok": False, "err": r.stderr or "squash crashed"}))


def prep(req, raw):
    d = json.loads(raw or "{}")
    # prep-for-push squash → smart subject, NO body (Phil's preference for squashed commits).
    # WHOLE branch (no --unpushed): collapse the entire parent..branch diff into ONE commit so the
    # PR is a single clean commit, no WIP. Safe now that stack-squash clamps a stale frozen .base
    # forward to merge-base(origin/main, branch) (squash-base-clamp), so it can't fold main's advance in.
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-squash"),
                 "--format", "--subject-only", d.get("branch", "")])
    req._send(200 if r.returncode == 0 else 500,
              r.stdout or json.dumps({"ok": False, "err": r.stderr or "prep crashed"}))
