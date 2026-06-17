# srv/review.py — the review surface: the forest model, per-node file list + diffs,
# commit log, branch purpose, blessing, and the squash/prep-for-push actions.
#   GET  /model?branch=X    the forest model JSON (stack-forest), cached on model_sig
#   GET  /node?branch=X     a node's file list (stack-forest --node)
#   GET  /purpose?branch=X  branch purpose/thesis (read; ?generate=1 opts into token spend)
#   GET  /file?branch&path  a file's contents on a ref (git show)
#   GET  /commits?branch=X  this branch's own commits (parent..branch)
#   POST /bless {branch,file}    mark file(s) reviewed (stack-bless)
#   POST /purpose {branch,text}  save a thesis as the branch description
#   POST /squash {branch}        collapse parent..branch into one commit
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
        _mcache.clear()
        _mcache[ck] = r.stdout
        req._send(200, r.stdout)


def node(req, u):
    q = parse_qs(u.query)
    branch = q.get("branch", [""])[0]
    base = q.get("base", [""])[0]
    args = [os.path.join(ctx.SCRIPTS, "stack-forest"), "--node", branch]
    if base:
        args += ["--base", base]
    r = ctx.run(args)
    req._send(200 if r.returncode == 0 else 500,
              r.stdout if r.returncode == 0 else json.dumps({"branch": branch, "files": []}))


def purpose_get(req, u):
    q = parse_qs(u.query)
    args = [os.path.join(ctx.SCRIPTS, "stack-purpose")]
    if q.get("generate", ["0"])[0] == "1":   # opt-in token spend, only on ask
        args.append("--generate")
    args.append(q.get("branch", [""])[0])
    r = ctx.run(args)
    req._send(200 if r.returncode == 0 else 500,
              r.stdout if r.returncode == 0 else json.dumps({"thesis": "", "enables": "", "source": "none"}))


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
    r = ctx.run(args)
    req._send(200 if r.returncode == 0 else 500,
              json.dumps({"ok": r.returncode == 0, "out": r.stdout, "err": r.stderr}))


def purpose_set(req, raw):
    d = json.loads(raw or "{}")
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-purpose"), "--set", d.get("text", ""), d.get("branch", "")])
    req._send(200 if r.returncode == 0 else 500, r.stdout if r.returncode == 0 else "{}")


def squash(req, raw):
    d = json.loads(raw or "{}")
    # squash button → smart subject, NO body (Phil's preference for squashed commits)
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-squash"), "--subject-only", d.get("branch", "")])
    # stack-squash always prints a JSON report (on success AND handled failure)
    req._send(200 if r.returncode == 0 else 500,
              r.stdout or json.dumps({"ok": False, "err": r.stderr or "squash crashed"}))


def prep(req, raw):
    d = json.loads(raw or "{}")
    # prep-for-push squash → smart subject, NO body (Phil's preference for squashed commits)
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-squash"),
                 "--unpushed", "--format", "--subject-only", d.get("branch", "")])
    req._send(200 if r.returncode == 0 else 500,
              r.stdout or json.dumps({"ok": False, "err": r.stderr or "prep crashed"}))
