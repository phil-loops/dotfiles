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

from . import ctx, picker

_mcache = {}  # (branch, model_sig) -> model json — recompute only when something changed


def _known_forest_name(name):
    """A real branch, or a name some stack config knows — stack-forest fabricates a
    one-node forest for ANY string, so /model must gate or /forests/<typo> renders a ghost."""
    if not name:
        return False
    if ctx.run(["git", "rev-parse", "--verify", "-q", f"refs/heads/{name}"]).returncode == 0:
        return True
    if ctx.run(["git", "config", "--get-all", f"stack-project.{name}.branch"]).stdout.strip():
        return True
    for line in ctx.run(["git", "config", "--get-regexp", r"^stack-branch\..*\.project$"]).stdout.splitlines():
        if line.partition(" ")[2].strip() == name:
            return True
    return False


def model(req, u):
    branch = parse_qs(u.query).get("branch", [""])[0]
    ck = (branch, ctx.model_sig())
    if ck in _mcache:
        req._send(200, _mcache[ck])
        return
    if not _known_forest_name(branch):
        req._send(404, json.dumps({"error": f"no branch or forest named {branch!r}"}))
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
        if bid in ranks:
            meta["mergeRank"] = ranks[bid]
    proj = picker._project_of(branch)
    if proj:
        iv = ctx.run(["git", "config", f"stack-project.{proj}.interest"]).stdout.strip()
        if iv.lstrip("-").isdigit() and int(iv) > 0:
            data["interest"] = int(iv)
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


def interest_bump(req, raw):
    # Promote/demote a forest's manual interest level (stack-project.<p>.interest). Body carries
    # {project, delta} (+1 promote / -1 demote) or {project, value} (absolute); {branch} resolves
    # to its project. Clamped ≥0; 0 unsets. Orders the Forests home; purely Phil's signal.
    d = json.loads(raw or "{}")
    proj = d.get("project", "") or (picker._project_of(d["branch"]) if d.get("branch") else "")
    if not proj:
        return req._send(400, json.dumps({"ok": False, "error": "no project for interest"}))
    key = f"stack-project.{proj}.interest"
    cur = ctx.run(["git", "config", key]).stdout.strip()
    cur = int(cur) if cur.lstrip("-").isdigit() else 0
    nxt = int(d["value"]) if "value" in d else cur + int(d.get("delta", 0))
    nxt = max(0, nxt)
    if nxt > 0:
        ctx.run(["git", "config", key, str(nxt)])
    else:
        ctx.run(["git", "config", "--unset", key])
    req._send(200, json.dumps({"ok": True, "project": proj, "interest": nxt}))


def _worktree_for_branch(branch):
    r = ctx.run(["git", "worktree", "list", "--porcelain"])
    if r.returncode != 0:
        return None
    wt_path = None
    for line in r.stdout.splitlines():
        if line.startswith("worktree "):
            wt_path = line[9:]
        elif line.startswith("branch refs/heads/") and line[18:] == branch:
            return wt_path
    return None


def _dirty_paths_of(wt):
    st = ctx.run(["git", "-C", wt, "status", "--porcelain"]).stdout.splitlines()
    return {l[3:].split(" -> ", 1)[-1].strip().strip('"') for l in st if len(l) > 3}


def commit_dirty(req, raw):
    # {branch, message, path?} — path narrows the commit to ONE dirty file (the rail's
    # per-file accept); membership in the worktree's actual dirt is the path guard.
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    message = (d.get("message") or "").strip()
    path = (d.get("path") or "").strip()
    if not branch or not message:
        req._send(400, json.dumps({"ok": False, "err": "branch and message required"}))
        return
    wt = _worktree_for_branch(branch)
    if not wt:
        req._send(400, json.dumps({"ok": False, "err": f"{branch!r} is not checked out in any worktree"}))
        return
    if path and path not in _dirty_paths_of(wt):
        req._send(400, json.dumps({"ok": False, "err": f"{path!r} isn't a dirty path in that worktree"}))
        return
    add_r = ctx.run(["git", "-C", wt, "add", "-A", *(["--", path] if path else [])])
    if add_r.returncode != 0:
        req._send(500, json.dumps({"ok": False, "err": add_r.stderr or "git add failed"}))
        return
    commit_r = ctx.run(["git", "-C", wt, "commit", "-m", message, *(["--", path] if path else [])])
    if commit_r.returncode != 0:
        req._send(500, json.dumps({"ok": False, "err": commit_r.stderr or "git commit failed"}))
        return
    req._send(200, json.dumps({"ok": True}))


def discard_dirty(req, raw):
    # {branch, path} — the rail's per-file reject: a tracked file restores to HEAD, an
    # untracked one is deleted. Destructive by design (the UI arms it); path must be a
    # member of the worktree's actual dirt and resolve inside the worktree.
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    path = (d.get("path") or "").strip()
    if not branch or not path:
        req._send(400, json.dumps({"ok": False, "err": "branch and path required"}))
        return
    wt = _worktree_for_branch(branch)
    if not wt:
        req._send(400, json.dumps({"ok": False, "err": f"{branch!r} is not checked out in any worktree"}))
        return
    if path not in _dirty_paths_of(wt):
        req._send(400, json.dumps({"ok": False, "err": f"{path!r} isn't a dirty path in that worktree"}))
        return
    tracked = ctx.run(["git", "-C", wt, "ls-files", "--error-unmatch", "--", path]).returncode == 0
    if tracked:
        r = ctx.run(["git", "-C", wt, "restore", "--staged", "--worktree", "--", path])
        if r.returncode != 0:
            req._send(500, json.dumps({"ok": False, "err": r.stderr or "restore failed"}))
            return
    else:
        fp = os.path.realpath(os.path.join(wt, path))
        if not fp.startswith(os.path.realpath(wt) + os.sep):
            req._send(400, json.dumps({"ok": False, "err": "path escapes the worktree"}))
            return
        try:
            os.remove(fp)
        except OSError as e:
            req._send(500, json.dumps({"ok": False, "err": str(e)}))
            return
    req._send(200, json.dumps({"ok": True, "discarded": path, "was": "tracked" if tracked else "untracked"}))


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
    # --unpushed: collapse only the commits past the branch's upstream, so an already-pushed branch
    # stays a fast-forward (no divergence / force-push surprise in GitHub Desktop). An unpushed branch
    # has no upstream, so stack-squash falls back to the frozen fork-point — the whole branch, as before.
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-squash"),
                 "--unpushed", "--format", "--subject-only", d.get("branch", "")])
    req._send(200 if r.returncode == 0 else 500,
              r.stdout or json.dumps({"ok": False, "err": r.stderr or "prep crashed"}))
