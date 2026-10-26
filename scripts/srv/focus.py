# srv/focus.py — keep the focus forests on current main without a click.
#
# Every POLL_S the server fetches origin/main. On a trunk move it fast-forwards local main and
# refreshes the gate donor; on every tick it restacks each focus forest that has fallen behind,
# one project at a time, with stack-restack --no-claude in the shared scratch worktree. A forest
# is left alone (and retried next tick) while any of its worktrees is dirty or has a process in
# it, while another restack runs or parks, or while its root is on origin (pushed, PR or not —
# a rebase there would leave the push door refusing a diverged branch). A conflict is
# aborted, never left parked — the forest carries the reason on /projects (`sync`), and is not
# retried until its branches or origin/main move.
import json
import os
import subprocess
import threading
import time

from . import ctx, restack, sync, watch

POLL_S = 90
_lock = threading.Lock()


def _state_path():
    return os.path.join(restack._gitdir(), "focus-sync.json")


def _load():
    try:
        with open(_state_path()) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {"tip": "", "projects": {}}


def _save(st):
    path = _state_path()
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w") as fh:
        json.dump(st, fh)
    os.replace(tmp, path)


def badge(project):
    """The forest's last ambient-sync outcome, for /projects — only the ones that need Phil."""
    ent = _load().get("projects", {}).get(project)
    return ent if ent and ent.get("state") in ("conflict", "stuck", "refused") else None


def _git(*args):
    return ctx.run(["git", *args])


def _tip(ref):
    return _git("rev-parse", "-q", "--verify", ref).stdout.strip()


def _focus_projects():
    out = _git("config", "--name-only", "--get-regexp", r"^stack-project\..*\.focus$").stdout
    return [line[len("stack-project."):-len(".focus")] for line in out.splitlines() if line]


def _members(project):
    names = _git("config", "--get-all", f"stack-project.{project}.branch").stdout.split()
    return [b for b in names if _tip(f"refs/heads/{b}")]


def _parent(branch):
    return _git("config", f"branch.{branch}.stack-parent").stdout.strip() \
        or _git("config", f"stack-branch.{branch}.parent").stdout.strip() or "main"


def _behind(branches):
    """Members whose parent tip isn't in their history (a root compares against origin/main)."""
    out = []
    for b in branches:
        p = _parent(b)
        ref = "origin/main" if p == "main" else p
        if _git("merge-base", "--is-ancestor", ref, b).returncode != 0:
            out.append(b)
    return out


def _sig(branches):
    return " ".join([_tip("origin/main")] + [f"{b}={_tip('refs/heads/' + b)}" for b in branches])


def _live_cwds():
    r = subprocess.run(["lsof", "-a", "-d", "cwd", "-Fn"], capture_output=True, text=True)
    return {line[1:] for line in r.stdout.splitlines() if line.startswith("n")}


def _busy(branches, cwds):
    """Why a member's worktree is off-limits: local changes, or a process working in it."""
    for b in branches:
        wt = restack._worktree_of(b)
        if not wt:
            continue
        if _git("-C", wt, "status", "--porcelain", "--untracked-files=no").stdout.strip():
            return f"{b}'s worktree has uncommitted changes"
        if any(c == wt or c.startswith(wt + "/") for c in cwds):
            return f"something is working in {b}'s worktree"
    return ""


def _gh_merged(branch):
    r = subprocess.run(["gh", "pr", "list", "--repo", "Loops-so/loops", "--state", "merged",
                        "--head", branch, "--json", "number", "--jq", "length"],
                       capture_output=True, text=True, cwd=ctx.repo_cwd())
    return r.returncode == 0 and r.stdout.strip() not in ("", "0")


def _ff_main(tip):
    cur = _tip("refs/heads/main")
    if not cur or cur == tip:
        return
    if _git("branch", "-f", "main", tip).returncode == 0:
        ctx.log(f"focus-sync: local main {cur[:9]} → {tip[:9]}")
        return
    wt = restack._worktree_of("main")
    if wt and not _git("-C", wt, "status", "--porcelain", "--untracked-files=no").stdout.strip() \
            and _git("-C", wt, "merge", "--ff-only", "-q", tip).returncode == 0:
        ctx.log(f"focus-sync: local main fast-forwarded in {wt} {cur[:9]} → {tip[:9]}")


def _restack(project):
    wt = restack.worktree()
    _git("-C", wt, "checkout", "--detach")
    with open(os.path.join(ctx.ROOT, "restack.log"), "ab") as lf:
        rc = subprocess.run([os.path.join(ctx.SCRIPTS, "stack-restack"), project, "--no-claude"],
                            cwd=wt, stdout=lf, stderr=lf).returncode
    parked, current = restack._parked()
    if parked:
        restack._clear_park()
    _git("-C", wt, "checkout", "--detach")
    watch.poke()
    return rc, current


def _sync_project(project, st, cwds):
    branches = _members(project)
    prev = st["projects"].get(project, {})
    now = int(time.time())
    behind = _behind(branches)
    if not behind:
        st["projects"][project] = prev if prev.get("state") == "synced" else {"state": "synced", "at": now}
        return False
    sig = _sig(branches)
    if prev.get("state") in ("conflict", "stuck", "refused") and prev.get("sig") == sig:
        return False
    roots = [b for b in branches if _parent(b) == "main"]
    open_prs = sync._open_pr_heads()
    if any(r in open_prs for r in roots):
        st["projects"][project] = {"state": "skipped", "why": "its base has an open PR"}
        return False
    if any(_tip(f"refs/remotes/origin/{r}") and not sync._already_merged(r) for r in roots):
        st["projects"][project] = {"state": "skipped", "why": "its base is pushed to origin"}
        return False
    for r in roots:
        if r in behind and sync._already_merged(r) and not _gh_merged(r):
            st["projects"][project] = {"state": "refused", "sig": sig, "at": now, "branch": r,
                                       "why": f"{r} looks merged locally but GitHub has no merged PR for it"}
            return True
    why = _busy(branches, cwds)
    if why:
        st["projects"][project] = {"state": "waiting", "why": why}
        return False
    ctx.log(f"focus-sync: restacking {project} ({len(behind)} behind)")
    rc, current = _restack(project)
    branches = _members(project)
    still = _behind(branches)
    now = int(time.time())
    if current:
        st["projects"][project] = {"state": "conflict", "sig": _sig(branches), "at": now, "branch": current,
                                   "why": f"{current} conflicts with its new base — restack it to resolve"}
    elif still:
        st["projects"][project] = {"state": "stuck", "sig": _sig(branches), "at": now, "branch": still[0],
                                   "why": f"{still[0]} didn't move (stack-restack exit {rc})"}
    else:
        st["projects"][project] = {"state": "synced", "at": now}
    ctx.log(f"focus-sync: {project} → {st['projects'][project]['state']}")
    return True


def tick():
    ctx.set_repo(ctx.CWD)
    _git("fetch", "-q", "origin", "main")
    tip = _tip("origin/main")
    if not tip:
        return
    with _lock:
        st = _load()
        changed = False
        if tip != st.get("tip"):
            _ff_main(tip)
            ctx.fire(["nice", "-n", "10", os.path.join(ctx.SCRIPTS, "stack-donor"), "--refresh", ctx.MAIN_WT],
                     cwd=ctx.MAIN_WT)
            st["tip"] = tip
            changed = True
        focus = _focus_projects()
        st["projects"] = {p: v for p, v in st.get("projects", {}).items() if p in focus}
        cwds = None
        for p in focus:
            if restack.blocked():
                break
            if cwds is None and _behind(_members(p)):
                cwds = _live_cwds()
            changed |= _sync_project(p, st, cwds or set())
        _save(st)
    if changed:
        ctx.bump_pulse()


def sync_forever():
    while True:
        try:
            tick()
        except Exception as e:
            ctx.log(f"focus-sync: tick failed: {e!r}")
        time.sleep(POLL_S)
