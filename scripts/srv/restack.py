# srv/restack.py — the restack endpoints and their helpers, lifted out of
# stack-review-server.py. Handlers receive `req` (the BaseHTTPRequestHandler) and
# reply via req._send(code, body). Shared state comes from srv.ctx (injected at boot).
#
#   POST /restack          restack one project (background, scratch worktree)
import os
import json
import time
import shlex
import shutil
import threading
import subprocess
from urllib.parse import parse_qs

from . import ctx
from . import agents


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


def _drivers():
    # Every LIVE restack driver as {pid, mode, project, etime}. Normally ≤1; two means a
    # tangle — concurrent drivers racing one worktree (the lock refuses the second now,
    # but we still surface the count as the safety net). _running() is the boolean form;
    # the Hearth needs the list, because a boolean can't tell one driver from two.
    base = os.path.join(ctx.SCRIPTS, "stack-restack")
    pids = subprocess.run(["pgrep", "-f", base], capture_output=True, text=True).stdout.split()
    if not pids:
        return []
    ps = subprocess.run(["ps", "-o", "pid=,etime=,command=", "-p", ",".join(pids)],
                        capture_output=True, text=True).stdout
    drivers = []
    for line in ps.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3:
            continue
        pid, etime, c = parts
        # Keep only the real invocation; drop the `zsh -c "… && git checkout"` parent so
        # wrapper+inner count as ONE driver (they bit us as two in the tangle).
        if (base + " ") not in c and (base + "-all") not in c:
            continue
        if "zsh -c" in c:
            continue
        mode = ("all" if "stack-restack-all" in c else "handoff" if "--handoff" in c
                else "diagnose" if "--diagnose" in c else "discard" if "--discard" in c
                else "continue" if "--continue" in c else "start")
        project = ""
        if mode != "all":
            after = c.split("stack-restack", 1)[1]
            project = next((t for t in after.split() if not t.startswith("-")), "")
        drivers.append({"pid": int(pid), "mode": mode, "project": project, "etime": etime})
    drivers.sort(key=lambda d: d["pid"])
    return drivers


def _state_path():
    gd = _gitdir()
    return os.path.join(gd, "stack-restack-state", "state") if gd else ""


def _queue_path():
    gd = _gitdir()
    return os.path.join(gd, "restack-queue") if gd else ""


def _queue_read():
    # Lines of "<kind> <project>", kind ∈ {now, batch}. "now" entries are interactive
    # (a sync click) and always sit ahead of "batch" ones; stack-restack-all also
    # splices "now" entries in between its own projects, so a sync never waits for a
    # whole sweep — only for the project currently mid-rebase.
    qp = _queue_path()
    if not qp or not os.path.exists(qp):
        return []
    entries = []
    with open(qp) as fh:
        for line in fh:
            parts = line.split()
            if len(parts) == 2 and parts[0] in ("now", "batch"):
                entries.append((parts[0], parts[1]))
    return entries


def _queue_write(entries):
    qp = _queue_path()
    if not qp:
        return
    tmp = qp + ".tmp"
    with open(tmp, "w") as fh:
        fh.writelines(f"{k} {p}\n" for k, p in entries)
    os.replace(tmp, qp)


_queue_lock = threading.Lock()


def _enqueue(project, kind="now"):
    # Dedup by project (a re-click refreshes position, never doubles the work); "now"
    # entries go after existing "now"s but ahead of every "batch".
    with _queue_lock:
        entries = [(k, p) for k, p in _queue_read() if p != project]
        if kind == "now":
            head = [e for e in entries if e[0] == "now"]
            tail = [e for e in entries if e[0] != "now"]
            entries = head + [("now", project)] + tail
        else:
            entries = entries + [("batch", project)]
        _queue_write(entries)
        return entries


def drain_forever():
    # Started once at server boot. Feeds queued restacks whenever the driver seat is
    # free — one project per pop, so an interactive request never waits behind more
    # than the project currently mid-rebase. A parked conflict pauses draining (it
    # needs a human or resolver first); the queue file is durable, so nothing queued
    # is lost across a server bounce. stack-restack-all splices "now" entries itself
    # between its projects — while it runs, _running() keeps this loop hands-off.
    while True:
        time.sleep(3)
        try:
            if not _queue_read() or _running():
                continue
            sp = _state_path()
            if sp and os.path.exists(sp):
                continue
            with _queue_lock:
                entries = _queue_read()
                if not entries:
                    continue
                (kind, project), rest = entries[0], entries[1:]
                _queue_write(rest)
            wt = worktree()
            ctx.run(["git", "-C", wt, "checkout", "--detach"])
            _spawn(cmd(project, wt), wt)
        except Exception:
            pass  # a transient (repo busy, disk hiccup) must never kill the drainer


def _running_msg():
    # Name the blocker: an anonymous "already running" sends the user hunting through
    # ps/reflogs for who's driving (a foreign session's run looks identical to a stuck one).
    ds = _drivers()
    if not ds:
        return "a restack is already running"
    d = ds[0]
    what = d["project"] or ("all projects" if d["mode"] == "all" else d["mode"])
    et = f" · {d['etime']} in" if d.get("etime") else ""
    more = f" (+{len(ds) - 1} more)" if len(ds) > 1 else ""
    return f"a restack is already running ({what}{et}{more})"


def blocked():
    # Don't start a restack while one is running or parked on a conflict — detaching
    # the scratch worktree under a live/paused rebase would corrupt it.
    if _running():
        return _running_msg()
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


def _spawn(chain, wt, register_kind=None, register_branch=""):
    logpath = os.path.join(ctx.ROOT, "restack.log")
    with open(logpath, "ab") as lf:
        proc = subprocess.Popen(["zsh", "-c", chain], cwd=wt, stdout=lf, stderr=lf)
    # a resolver handoff spawns its claude with no tmux window, so it registers itself here — that's
    # how /processes surfaces the agent (the reaper walks this pid's tree to confirm it's live).
    if register_kind:
        agents.register(register_kind, register_branch, proc.pid, worktree=wt)
    return logpath



def restack(req, raw):
    d = json.loads(raw or "{}")
    project = d.get("project", "")
    if not project or project in ("whole forest", "--all"):
        req._send(400, json.dumps({"ok": False, "err": "no registered project to restack"}))
        return
    if _running():
        # Don't refuse — queue it. The drainer (or a running stack-restack-all, at its
        # next project boundary) picks it up the moment the current project finishes.
        entries = _enqueue(project, "now")
        ds = _drivers()
        behind = ds[0]["project"] if ds and ds[0].get("project") else "the running restack"
        ahead = next(i for i, (_, p) in enumerate(entries) if p == project)
        req._send(200, json.dumps({"ok": True, "project": project, "queued": True,
                                   "behind": behind, "ahead": ahead}))
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

