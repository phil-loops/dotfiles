"""A rebase canopy starts records its owner, so one interrupted by a death is aborted by the next
run instead of stranding the worktree (P1: a claim dies with its holder). 2026-11-17: sync left
a half-finished rebase in a branch's worktree twice ("used by worktree", detached HEAD).

The record (`<worktree git dir>/canopy-rebase-owner`: pid + process start time) is written
before `git rebase` runs and removed once no rebase is in progress. A later guarded run, or
`rebase-guarded --heal`, aborts an in-progress rebase whose recorded owner is no longer alive.
An in-progress rebase with NO record was started by a person: it is never aborted, only refused.

Plain subprocess, not ctx.run, so the `rebase-guarded` CLI can use it outside the server."""
import json
import os
import subprocess

OWNER = "canopy-rebase-owner"
_SCRUB = ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE", "GIT_PREFIX")


def _git(wt, *args):
    env = {k: v for k, v in os.environ.items() if k not in _SCRUB}
    return subprocess.run(["git", "-C", wt, *args], capture_output=True, text=True, env=env)


def _gitdir(wt):
    r = _git(wt, "rev-parse", "--absolute-git-dir")
    return r.stdout.strip() if r.returncode == 0 else ""


def in_progress(wt):
    gd = _gitdir(wt)
    return bool(gd) and (os.path.isdir(os.path.join(gd, "rebase-merge")) or os.path.isdir(os.path.join(gd, "rebase-apply")))


def _start(pid):
    r = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True)
    return r.stdout.strip()


def _alive(rec):
    pid = rec.get("pid")
    if not isinstance(pid, int):
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    return _start(pid) == rec.get("start")   # a reused pid is a different process


def _owner_path(wt):
    gd = _gitdir(wt)
    return os.path.join(gd, OWNER) if gd else ""


def _read(wt):
    p = _owner_path(wt)
    try:
        with open(p) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def heal(wt):
    """'clear' — no rebase in progress; 'healed' — aborted a dead owner's rebase; 'live' — our
    own rebase is still running; 'person' — a rebase with no record (someone's, never touched)."""
    if not in_progress(wt):
        p = _owner_path(wt)
        if p and os.path.exists(p):
            os.remove(p)
        return "clear"
    rec = _read(wt)
    if rec is None:
        return "person"
    if _alive(rec):
        return "live"
    _git(wt, "rebase", "--abort")
    if in_progress(wt):
        return "person"   # git refused the abort: leave it for a person, say so
    os.remove(_owner_path(wt))
    return "healed"


def run(wt, args, owner_pid=None, abort=True):
    """`git -C wt rebase <args>` with an owner record; aborts on failure. Returns a
    CompletedProcess. A person's rebase in progress is refused (returncode 3). abort=False
    leaves a failed rebase stopped so the caller can read its conflicts and then abort it; the
    record stays meanwhile, so a death before that abort is still healed."""
    state = heal(wt)
    if state in ("person", "live"):
        return subprocess.CompletedProcess(["git", "rebase", *args], 3, "",
                                           f"a rebase is already in progress in {wt} — finish or abort it first")
    pid = owner_pid or os.getpid()
    p = _owner_path(wt)
    with open(p, "w") as f:
        json.dump({"pid": pid, "start": _start(pid)}, f)
    try:
        r = _git(wt, "rebase", *args)
        if r.returncode != 0 and abort and in_progress(wt):
            _git(wt, "rebase", "--abort")
        return r
    finally:
        if not in_progress(wt) and os.path.exists(p):
            os.remove(p)
