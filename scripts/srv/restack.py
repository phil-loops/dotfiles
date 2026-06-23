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
import shutil
import subprocess
from urllib.parse import parse_qs

from . import ctx


def _gitdir():
    # Absolute git-common-dir — shared across linked worktrees, so the restack state +
    # conflict artifacts live in ONE place regardless of which worktree the run is in.
    gd = ctx.run(["git", "rev-parse", "--git-common-dir"]).stdout.strip()
    if gd and not os.path.isabs(gd):
        gd = os.path.join(ctx.CWD, gd)
    return gd


def _worktree_of(branch):
    # The worktree a branch is currently checked out in (mirrors stack-restack's helper).
    if not branch:
        return ""
    out = ctx.run(["git", "worktree", "list", "--porcelain"]).stdout
    cur = ""
    for line in out.splitlines():
        if line.startswith("worktree "):
            cur = line[len("worktree "):]
        elif line == f"branch refs/heads/{branch}":
            return cur
    return ""


def _parked():
    # Read the parked conflict's PROJECT/CURRENT from the state file, or ("", "") if none.
    sd = _state_path()
    if not sd or not os.path.exists(sd):
        return "", ""
    with open(sd) as fh:
        kv = dict(l.rstrip("\n").split("=", 1) for l in fh
                  if "=" in l and not l.startswith("SNAP"))
    return kv.get("PROJECT", ""), kv.get("CURRENT", "")


def _clear_park():
    # Undo a parked rebase the same way `stack-restack --abort` + manual abort would:
    # abort the in-progress rebase in whatever worktree it parked in, then drop the
    # state dir + diagnosis artifacts. Background restacks park DETACHED in the scratch
    # worktree (so worktree_of can't name them) — abort there too, not just the branch's
    # own worktree. Only ever touches a rebase the parked state points at.
    proj, cur = _parked()
    for wt in {_worktree_of(cur), worktree()}:
        if wt:
            ctx.run(["git", "-C", wt, "rebase", "--abort"])
            ctx.run(["git", "-C", wt, "checkout", "--detach"])
    gd = _gitdir()
    if gd:
        shutil.rmtree(os.path.join(gd, "stack-restack-state"), ignore_errors=True)
        for f in ("stack-restack-conflict.json", "stack-restack-conflict-snapshot"):
            try:
                os.remove(os.path.join(gd, f))
            except OSError:
                pass
    return proj


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


def _running():
    # Match the actual INVOCATION (absolute script path + a following arg), not any
    # process that merely mentions the string: a `git diff scripts/stack-restack`
    # watcher or an editor with the file open used to false-positive this and 409 every
    # restack. The real run is `<SCRIPTS>/stack-restack <project> …` (abs path + space)
    # or the resilient wrapper `<SCRIPTS>/stack-restack-all`; watchers use the relative
    # path and editors have no trailing arg, so neither matches.
    base = os.path.join(ctx.SCRIPTS, "stack-restack")
    for pat in (base + " ", base + "-all"):
        if subprocess.run(["pgrep", "-f", pat], capture_output=True).returncode == 0:
            return True
    return False


def _state_path():
    gd = _gitdir()
    return os.path.join(gd, "stack-restack-state", "state") if gd else ""


def blocked():
    # Don't start a restack while one is running or parked on a conflict — detaching
    # the scratch worktree under a live/paused rebase would corrupt it.
    if _running():
        return "a restack is already running"
    sp = _state_path()
    if sp and os.path.exists(sp):
        return "a restack is parked on a conflict — resolve it first"
    return ""


def cmd(project, wt, action=None):
    # action: None = fresh restack, "handoff" = AI-resolve the parked conflict + resume,
    # "diagnose" = AI-resolve + stage the parked conflict for review (no resume),
    # "discard"  = drop a staged diagnose fix, restoring the parked conflict.
    #
    # On clean success, detach the scratch worktree so it doesn't keep the last
    # rebased branch checked out (locking it from other worktrees). On a conflict-pause
    # stack-restack exits non-zero and `&&` short-circuits — the parked rebase is left
    # intact for /restack-resolve to resume.
    parts = [shlex.quote(os.path.join(ctx.SCRIPTS, "stack-restack")), shlex.quote(project)]
    if action in ("diagnose", "discard"):
        # Both leave the rebase parked. No worktree-detach tail — nothing finished,
        # and detaching mid-park would fight the parked rebase.
        parts.append("--diagnose" if action == "diagnose" else "--discard")
        return " ".join(parts)
    if action == "handoff":
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
    sd = _state_path()
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
    running = _running()
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
        parked, current = _parked()
        req._send(409, json.dumps({"ok": False, "err": b, "parked": parked, "current": current}))
        return
    wt = worktree()
    ctx.run(["git", "-C", wt, "checkout", "--detach"])  # release any branch held from a prior run
    logpath = _spawn(cmd(project, wt), wt)
    req._send(200, json.dumps({"ok": True, "project": project, "log": logpath}))


def resolve(req, raw):
    # One endpoint, three intents via `mode`:
    #   "resolve"  (default) — AI-fix the parked conflict + resume the cascade
    #   "diagnose"           — AI-resolve + stage it for review (no resume) → conflict.json
    #   "discard"            — drop a staged diagnose fix, restoring the parked conflict
    d = json.loads(raw or "{}")
    project = d.get("project", "")
    mode = d.get("mode", "resolve")
    if not project:
        req._send(400, json.dumps({"ok": False, "err": "no project"}))
        return
    wt = worktree()
    action = {"diagnose": "diagnose", "discard": "discard"}.get(mode, "handoff")
    logpath = _spawn(cmd(project, wt, action=action), wt)
    req._send(200, json.dumps({"ok": True, "project": project, "mode": mode, "log": logpath}))


def abort(req, raw):
    # Discard the parked rebase entirely (the human chose "give up on this conflict"):
    # abort the in-progress rebase in whatever worktree it parked in + drop the state.
    # Non-destructive to commits — the project's branches keep their pre-restack tips and
    # can be restacked again later. Refuses while a restack PROCESS is actively churning.
    if _running():
        req._send(409, json.dumps({"ok": False, "err": "a restack is still running"}))
        return
    project = _clear_park()
    req._send(200, json.dumps({"ok": True, "project": project}))


def conflict(req, u):
    # Serve the structured diagnosis artifact stack-restack --diagnose writes to
    # <git-common-dir>/stack-restack-conflict.json (same dir-resolution as status()).
    # {present:false} when absent or scoped to a different project than requested.
    gitdir = _gitdir()
    path = os.path.join(gitdir, "stack-restack-conflict.json") if gitdir else ""
    want = parse_qs(u.query).get("project", [""])[0]
    if not path or not os.path.exists(path):
        req._send(200, json.dumps({"present": False}))
        return
    try:
        with open(path) as fh:
            art = json.load(fh)
    except Exception as e:
        req._send(200, json.dumps({"present": False, "err": str(e)}))
        return
    if want and art.get("project") and art.get("project") != want:
        req._send(200, json.dumps({"present": False}))
        return
    req._send(200, json.dumps({"present": True, "conflict": art}))


def restack_all(req, raw):
    d = json.loads(raw or "{}")
    projects = [p for p in d.get("projects", []) if p and p not in ("whole forest", "--all")]
    if not projects:
        req._send(400, json.dumps({"ok": False, "err": "no projects"}))
        return
    if _running():
        req._send(409, json.dumps({"ok": False, "err": "a restack is already running"}))
        return
    parked, current = _parked()
    if parked and not d.get("abortParked"):
        # A pre-existing park holds a worktree mid-rebase; restacking the rest needs it
        # freed first. Surface it so the UI can offer one-click "abort & restack all".
        req._send(409, json.dumps({"ok": False, "err": "a restack is parked on a conflict — resolve it first",
                                   "parked": parked, "current": current}))
        return
    if parked:
        _clear_park()
    wt = worktree()
    ctx.run(["git", "-C", wt, "checkout", "--detach"])
    # stack-restack-all is resilient: a project that conflicts is aborted + skipped so the
    # rest still restack, and the first problem re-parks at the end to surface its button.
    argv = " ".join(shlex.quote(p) for p in projects)
    logpath = _spawn(f"{shlex.quote(os.path.join(ctx.SCRIPTS, 'stack-restack-all'))} {argv}", wt)
    req._send(200, json.dumps({"ok": True, "projects": projects, "log": logpath}))
