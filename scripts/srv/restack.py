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
import time
import shlex
import shutil
import signal
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


def _resolvers():
    # Live conflict-resolvers, counted from the agent registry — each registers itself at _spawn
    # below. >1 on one conflict is the duplicate-spawn half of the tangle. Was a prompt-signature
    # pgrep (brittle: broke on any reword); now the resolvers register, so this counts their records.
    return sum(1 for a in agents.live() if a.get("kind") == "resolver")


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


def _journal_last():
    # stack-restack appends one line per done/parked/aborted exit; the last line says what
    # the most recent run was, so a run that ended before anyone looked stays identifiable.
    try:
        with open(os.path.join(_gitdir(), "stack-restack-journal")) as fh:
            parts = fh.readlines()[-1].split()
        entry = {"at": int(parts[0]), "project": parts[1], "result": parts[2]}
        for kv in parts[3:]:
            if "=" in kv:
                k, v = kv.split("=", 1)
                entry[k] = v
        return entry
    except Exception:
        return None


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


def ambient(req):
    # The ambient daemon (scripts/restack-daemon) writes its latest DRY-RUN report to
    # <git-common-dir>/restack-ambient.json on every origin/main tip change. This serves it
    # verbatim for the viewer's status chip — read-only, no classification on the request path
    # (the daemon already did it). available=false simply means the daemon hasn't run here yet.
    path = os.path.join(_gitdir(), "restack-ambient.json")
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        req._send(200, json.dumps({"available": False}))
        return
    data["available"] = True
    data["age_s"] = int(time.time() - data.get("at", 0)) if data.get("at") else None
    req._send(200, json.dumps(data))


def merges(req):
    # restack-daemon also writes restack-merges.json on every trunk move: which PRs the
    # new commits belong to (parsed from the squash subjects, enriched via one gh call)
    # and whether any are the user's own. Served verbatim for the "just landed" chip.
    path = os.path.join(_gitdir(), "restack-merges.json")
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        req._send(200, json.dumps({"available": False}))
        return
    data["available"] = True
    data["age_s"] = int(time.time() - data.get("at", 0)) if data.get("at") else None
    req._send(200, json.dumps(data))


def status(req, u):
    # stack-restack rewrites <git-common-dir>/stack-restack-state/state before and after
    # every branch of the walk (removed on success/abort), so during a run it's the live
    # progress feed; it only means "parked" once no driver is alive to advance it.
    sd = _state_path()
    want = parse_qs(u.query).get("project", [""])[0]
    state_present, proj, cur = False, "", ""
    done = total = 0
    completed, pending = [], []
    if sd and os.path.exists(sd):
        state_present = True
        with open(sd) as fh:
            kv = dict(l.rstrip("\n").split("=", 1) for l in fh
                      if "=" in l and not l.startswith("SNAP"))
        proj, cur = kv.get("PROJECT", ""), kv.get("CURRENT", "")
        # COMPLETED/PENDING are space-joined branch lists; CURRENT is the in-flight one
        # (popped from PENDING, not in either list) → it's node done+1 of total. The lists
        # also drive the forest-map kiln (per-branch set/current/pending heat-front).
        completed = kv.get("COMPLETED", "").split()
        pending = kv.get("PENDING", "").split()
        done = len(completed)
        total = done + len(pending) + (1 if cur else 0)
    running = _running()
    # paused == "escalated, needs a human": state left behind with no driver alive. State
    # + a live driver is just a walk in progress — reporting that as paused made the home
    # screen paint every healthy run as a parked conflict.
    # Parked also means RESUMABLE: the walk stopped ON a branch a human can pick back up.
    # If that branch (or, between nodes, every pending branch) no longer exists, the
    # forest was reshaped out from under the state file — an orphan, not a park; reporting
    # it paused dimmed the whole map for days (2026-08-27). Classify only, never delete:
    # a bare status check stays read-only.
    def _branch_exists(b):
        return ctx.run(["git", "show-ref", "--verify", "--quiet",
                        f"refs/heads/{b}"]).returncode == 0
    orphaned = state_present and not running and (
        not _branch_exists(cur) if cur else not any(_branch_exists(b) for b in pending))
    paused = state_present and not running and not orphaned and ((not want) or proj == want)
    reason = ""
    if paused:
        try:
            with open(os.path.join(ctx.ROOT, "restack.log")) as fh:
                for line in fh:
                    if "claude escalated:" in line:
                        reason = line.split("claude escalated:", 1)[1].strip()
        except Exception:
            pass
    req._send(200, json.dumps({"paused": paused, "orphaned": orphaned,
                               "project": proj, "current": cur,
                               "running": running, "reason": reason,
                               "done": done, "total": total,
                               "completed": completed, "pending": pending,
                               "drivers": _drivers(), "resolvers": _resolvers(),
                               "queue": [{"kind": k, "project": p} for k, p in _queue_read()],
                               "last": _journal_last()}))


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
    logpath = _spawn(cmd(project, wt, action=action), wt, register_kind="resolver", register_branch=project)
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


def stop(req, raw):
    # Stop a RUNNING restack walk — vs. abort(), which only clears a PARKED conflict. SIGTERM the
    # drivers first; stack-restack-all traps TERM (to release its lock) and won't exit on it, so
    # SIGKILL the survivors — untrappable. Then abort any in-progress rebase + drop state + clear
    # the now-stale lock. Non-destructive: completed branches keep their restacked tips, the
    # current/pending are dropped and can be restacked again later.
    def _pids():
        return [d["pid"] for d in _drivers() if d.get("pid")]

    killed = _pids()
    for pid in killed:
        try:
            os.kill(pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
    time.sleep(0.6)
    for pid in _pids():
        try:
            os.kill(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    project = _clear_park()
    try:
        os.remove(os.path.join(_gitdir(), "stack-restack.lock"))
    except OSError:
        pass
    req._send(200, json.dumps({"ok": True, "stopped": killed, "project": project}))


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
        req._send(409, json.dumps({"ok": False, "err": _running_msg(),
                                   "drivers": _drivers()}))
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
