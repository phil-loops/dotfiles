# srv/restack.py — the restack endpoints and their helpers, lifted out of
# stack-review-server.py. Handlers receive `req` (the BaseHTTPRequestHandler) and
# reply via req._send(code, body). Shared state comes from srv.ctx (injected at boot).
#
#   GET  /restack-status   paused/running/reason for the picker badge
#   POST /restack          restack one project (background, scratch worktree)
#   POST /restack-resolve  hand a parked conflict to Claude, then resume
#   POST /restack-all      restack several projects back-to-back in one job
import os
import json
import shlex
import subprocess
from urllib.parse import parse_qs

from . import ctx


def worktree():
    # Background restacks run in a dedicated detached worktree, NOT the user's main
    # checkout — stack-restack checks out each un-worktree'd branch in its cwd to
    # rebase it, so keep that bouncing off MAIN_WT. Created once, reused thereafter.
    path = os.path.join(os.path.dirname(ctx.MAIN_WT) or ".", ".loops-restack-wt")
    listing = ctx.run(["git", "worktree", "list", "--porcelain"]).stdout
    if not any(os.path.realpath(line[len("worktree "):]) == os.path.realpath(path)
               for line in listing.splitlines() if line.startswith("worktree ")):
        ctx.run(["git", "worktree", "add", "--detach", path, "HEAD"])
    return path


def blocked():
    # Don't start a restack while one is running or parked on a conflict — detaching
    # the scratch worktree under a live/paused rebase would corrupt it.
    if subprocess.run(["pgrep", "-f", "stack-restack"], capture_output=True).returncode == 0:
        return "a restack is already running"
    gitdir = ctx.run(["git", "rev-parse", "--git-common-dir"]).stdout.strip()
    if gitdir and not os.path.isabs(gitdir):
        gitdir = os.path.join(ctx.CWD, gitdir)
    if gitdir and os.path.exists(os.path.join(gitdir, "stack-restack-state", "state")):
        return "a restack is parked on a conflict — resolve it first"
    return ""


def cmd(project, wt, handoff=False):
    # On clean success, detach the scratch worktree so it doesn't keep the last
    # rebased branch checked out (locking it from other worktrees). On a conflict-pause
    # stack-restack exits non-zero and `&&` short-circuits — the parked rebase is left
    # intact for /restack-resolve to resume.
    parts = [shlex.quote(os.path.join(ctx.SCRIPTS, "stack-restack")), shlex.quote(project)]
    if handoff:
        parts.append("--handoff")
    return " ".join(parts) + f" && git -C {shlex.quote(wt)} checkout --detach >/dev/null 2>&1"


def _spawn(chain, wt):
    logpath = os.path.join(ctx.ROOT, "restack.log")
    with open(logpath, "ab") as lf:
        subprocess.Popen(["zsh", "-c", chain], cwd=wt, stdout=lf, stderr=lf)
    return logpath


def status(req, u):
    # stack-restack writes <git-common-dir>/stack-restack-state/state on a conflict it
    # can't auto-resolve (removed on success/abort). Its presence == paused.
    gitdir = ctx.run(["git", "rev-parse", "--git-common-dir"]).stdout.strip()
    if gitdir and not os.path.isabs(gitdir):
        gitdir = os.path.join(ctx.CWD, gitdir)
    sd = os.path.join(gitdir, "stack-restack-state", "state") if gitdir else ""
    want = parse_qs(u.query).get("project", [""])[0]
    paused, proj, cur = False, "", ""
    if sd and os.path.exists(sd):
        with open(sd) as fh:
            kv = dict(l.rstrip("\n").split("=", 1) for l in fh
                      if "=" in l and not l.startswith("SNAP"))
        proj, cur = kv.get("PROJECT", ""), kv.get("CURRENT", "")
        paused = (not want) or proj == want
    # running==False + paused==True means "escalated, needs a human" (the parent
    # stack-restack stays alive across the whole walk and exits when it escalates).
    running = subprocess.run(["pgrep", "-f", "stack-restack"],
                             capture_output=True, text=True).returncode == 0
    reason = ""
    if paused:
        try:
            with open(os.path.join(ctx.ROOT, "restack.log")) as fh:
                for line in fh:
                    if "claude escalated:" in line:
                        reason = line.split("claude escalated:", 1)[1].strip()
        except Exception:
            pass
    req._send(200, json.dumps({"paused": paused, "project": proj, "current": cur,
                               "running": running, "reason": reason}))


def restack(req, raw):
    d = json.loads(raw or "{}")
    project = d.get("project", "")
    if not project or project in ("whole forest", "--all"):
        req._send(400, json.dumps({"ok": False, "err": "no registered project to restack"}))
        return
    b = blocked()
    if b:
        req._send(409, json.dumps({"ok": False, "err": b}))
        return
    wt = worktree()
    ctx.run(["git", "-C", wt, "checkout", "--detach"])  # release any branch held from a prior run
    logpath = _spawn(cmd(project, wt), wt)
    req._send(200, json.dumps({"ok": True, "project": project, "log": logpath}))


def resolve(req, raw):
    d = json.loads(raw or "{}")
    project = d.get("project", "")
    if not project:
        req._send(400, json.dumps({"ok": False, "err": "no project"}))
        return
    wt = worktree()
    logpath = _spawn(cmd(project, wt, handoff=True), wt)
    req._send(200, json.dumps({"ok": True, "project": project, "log": logpath}))


def restack_all(req, raw):
    d = json.loads(raw or "{}")
    projects = [p for p in d.get("projects", []) if p and p not in ("whole forest", "--all")]
    if not projects:
        req._send(400, json.dumps({"ok": False, "err": "no projects"}))
        return
    b = blocked()
    if b:
        req._send(409, json.dumps({"ok": False, "err": b}))
        return
    wt = worktree()
    ctx.run(["git", "-C", wt, "checkout", "--detach"])
    # Chain with `&&` so a conflict-park (non-zero exit) HALTS the sequence — the
    # parked project surfaces via /restack-status; resolve it, then re-run for the rest.
    chain = " && ".join(cmd(p, wt) for p in projects)
    logpath = _spawn(chain, wt)
    req._send(200, json.dumps({"ok": True, "projects": projects, "log": logpath}))
