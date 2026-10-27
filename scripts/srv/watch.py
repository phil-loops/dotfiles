# srv/watch.py — notice repo changes by STAT, not by spawning git.
#
# Everything the read verdicts derive from lives in a handful of places under the common git
# dir, and git only ever changes them by lock-file + rename: a loose ref update renames into its
# directory (bumping that directory's mtime), packed-refs/config/HEADs are replaced whole, and a
# worktree add/remove touches worktrees/. So one os.stat walk over those paths — ~15ms at 260 ref
# dirs and 440 worktrees, no spawn — answers "did anything move?" and the generation counter
# below turns that into a cheap cache key. Readers that still have to ask git (RepoState's
# snapshot, model_sig) now do so only when the generation moved, plus a slow safety re-check.
#
# Working-tree dirt is the one input no git-dir stat sees (an editor save touches neither the
# index nor any ref), so it gets its own stamp: `status --porcelain` on the worktrees holding a
# branch, plus each dirty path's (mtime, size) so an edit to an already-modified file still counts.
import hashlib
import os
import subprocess
import threading
import time

from . import ctx

_THROTTLE = 0.25   # seconds a stat walk's answer is reused — the pulse and a request burst share it
_LOCK = threading.Lock()
_STATE = {}   # git common dir -> {"at", "fp", "gen", "holders": (gen, {branch: [(path, attached)]})}
_GD = {}      # repo cwd -> absolute git common dir


def common_dir(repo=None):
    repo = repo or ctx.repo_cwd()
    gd = _GD.get(repo)
    if gd is None:
        gd = ctx.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"]).stdout.strip()
        if gd:
            _GD[repo] = gd
    return gd


def _mtime(path):
    try:
        st = os.stat(path)
        return (st.st_mtime_ns, st.st_size)
    except OSError:
        return None


def _walk(gd):
    acc = []
    for root, _dirs, _files in os.walk(os.path.join(gd, "refs")):
        acc.append((root, _mtime(root)))
    for name in ("packed-refs", "config", "HEAD"):
        acc.append((name, _mtime(os.path.join(gd, name))))
    wts = os.path.join(gd, "worktrees")
    acc.append(("worktrees", _mtime(wts)))
    try:
        names = sorted(os.listdir(wts))
    except OSError:
        names = []
    for n in names:
        acc.append((n, _mtime(os.path.join(wts, n, "HEAD"))))
    return hashlib.sha1(repr(acc).encode()).hexdigest()


def _entry(gd):
    now = time.monotonic()
    with _LOCK:
        ent = _STATE.setdefault(gd, {"at": -1e9, "fp": None, "gen": 0, "holders": None})
        if now - ent["at"] < _THROTTLE:
            return ent
    fp = _walk(gd)
    with _LOCK:
        if fp != ent["fp"]:
            ent["fp"], ent["gen"] = fp, ent["gen"] + 1
        ent["at"] = now
    return ent


def poke(repo=None):
    """Forget the throttle: this server just wrote to the repo, so the next generation() walks."""
    gd = common_dir(repo)
    with _LOCK:
        if gd in _STATE:
            _STATE[gd]["at"] = -1e9


def generation(repo=None):
    """A counter that moves whenever a ref, the config, a HEAD, or the
    worktree set changes. Equal generations mean none of those moved in between."""
    gd = common_dir(repo)
    return _entry(gd)["gen"] if gd else -1


def _read(path):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return ""


def _holders_map(gd):
    # {branch: [(worktree path, attached)]} from the files `git worktree list` itself reads:
    # the main worktree's HEAD, and each linked worktree's HEAD + gitdir pointer. Detached
    # stack-open scratch trees name their branch in a stack-open-branch marker.
    out = {}

    def add(path, head_file, admin):
        head = _read(head_file)
        if head.startswith("ref: refs/heads/"):
            out.setdefault(head[len("ref: refs/heads/"):], []).append((path, True))
        elif admin:
            b = _read(os.path.join(admin, "stack-open-branch"))
            if b:
                out.setdefault(b, []).append((path, False))

    if os.path.basename(gd) == ".git":
        add(os.path.dirname(gd), os.path.join(gd, "HEAD"), None)
    wts = os.path.join(gd, "worktrees")
    try:
        names = sorted(os.listdir(wts))
    except OSError:
        names = []
    for n in names:
        admin = os.path.join(wts, n)
        pointer = _read(os.path.join(admin, "gitdir"))
        if pointer:
            add(os.path.dirname(pointer), os.path.join(admin, "HEAD"), admin)
    return out


def holders(branch, repo=None):
    """Every worktree that could hold <branch>: [(path, attached)] — attached ones have it
    checked out, detached ones are stack-open scratch trees tagged with it. No spawn; cached
    per generation (a HEAD move or a worktree add/remove bumps it)."""
    gd = common_dir(repo)
    if not gd:
        return []
    ent = _entry(gd)
    gen = ent["gen"]
    cached = ent["holders"]
    if cached is None or cached[0] != gen:
        cached = (gen, _holders_map(gd))
        with _LOCK:
            ent["holders"] = cached
    return cached[1].get(branch, [])


def dirt_stamp(paths):
    """Fingerprint of the uncommitted state of these worktrees: porcelain status (untracked
    included) plus every listed path's (mtime, size), so re-editing an already-dirty file
    changes it too. One `status` spawn per worktree, run in parallel."""
    if not paths:
        return ""

    def one(wt):
        st = subprocess.run(["git", "--no-optional-locks", "-C", wt, "status", "--porcelain"],
                            capture_output=True, text=True).stdout
        stats = []
        for ln in st.splitlines():
            if len(ln) > 3:
                p = ln[3:].split(" -> ", 1)[-1].strip().strip('"')
                stats.append((p, _mtime(os.path.join(wt, p))))
        return repr((wt, st, stats))

    if len(paths) == 1:
        parts = [one(paths[0])]
    else:
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=min(8, len(paths))) as ex:
            parts = list(ex.map(one, paths))
    return hashlib.sha1("\x1e".join(parts).encode()).hexdigest()
