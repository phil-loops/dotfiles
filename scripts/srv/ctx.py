# srv/ctx.py — shared state for the handler modules, injected ONCE by the main
# server at startup. Lets concern-specific handlers (restack, sync, picker, …) be
# lifted out of the stack-review-server.py monolith without threading run()/paths
# through every call — so concurrent sessions edit different files, not one giant one.
import os
import hashlib
import threading

run = None      # run(argv, timeout=None) -> CompletedProcess, cwd=repo_cwd(); expiry = rc 124


def log(line):
    # replaced by the server's durable logger at init; stderr is the fallback so a srv module
    # imported outside the server (the fixture harness) still says things out loud
    print(line, file=__import__("sys").stderr)
ROOT = ""       # servedir (where restack.log / index.html live)
SCRIPTS = ""    # ~/.dotfiles/scripts
CWD = ""        # the repo the server was launched in (the default when no ?repo= is selected)
MAIN_WT = ""    # the repo's primary worktree (checkout-here / restack targets)
REPOS = {}      # multi-repo registry: name -> main worktree path (drives /projects aggregation)

# Per-request active repo. The server is ThreadingHTTPServer (one thread per request), so a
# request can pin its repo here and every ctx.run/ctx.repo_cwd in that handler operates on it
# without threading a repo arg through every signature. Pool workers don't inherit a thread-local,
# so fan-outs must seed it explicitly (ThreadPoolExecutor(initializer=set_repo, initargs=(path,))).
_local = threading.local()


# Bumped when a background rebuild replaces a cache entry the page is already showing. The
# pulse fingerprint includes it, so the tabs holding the stale payload refetch — without it a
# stale-while-revalidate answer would sit on screen until the next unrelated git change.
pulse_nonce = [0]


def bump_pulse():
    pulse_nonce[0] += 1


def fire(argv, **kw):
    """Fire-and-forget a child — reaped by a waiter thread, so it can't linger as <defunct>."""
    import subprocess
    kw.setdefault("stdout", subprocess.DEVNULL)
    kw.setdefault("stderr", subprocess.DEVNULL)
    proc = subprocess.Popen(argv, **kw)
    threading.Thread(target=proc.wait, daemon=True).start()
    return proc


def set_repo(path):
    _local.repo = path


def clear_repo():
    _local.repo = None


def repo_cwd():
    return getattr(_local, "repo", None) or CWD


def repo_name():
    """The registry name of the repo this request is pinned to (the server's own by default) —
    the <repo> segment of a v2 path."""
    here = os.path.realpath(repo_cwd())
    main = os.path.realpath(MAIN_WT) if here == os.path.realpath(CWD) else here
    for name, path in (REPOS or {}).items():
        if os.path.realpath(path) in (here, main):
            return name
    return os.path.basename(main)


def repo_path(name):
    # registry resolver: a viewer-repos name -> its main worktree, or None for an unknown name
    # (callers 400 rather than silently bind to the wrong repo).
    return REPOS.get(name)


# Open /events streams. The server owns the counting; background threads read it to decide
# whether speculative work is worth doing at all — idle has to be genuinely free, or the
# server can't be left running (which is the root of the whole resurrection apparatus).
PULSE_SUBS = [0]


def watched():
    return PULSE_SUBS[0] > 0


def init(*, run, ROOT, SCRIPTS, CWD, MAIN_WT, repos, log=None):
    from . import fastgit
    g = globals()
    g["run"], g["ROOT"], g["SCRIPTS"], g["CWD"], g["MAIN_WT"], g["REPOS"] = (
        fastgit.wrap(run), ROOT, SCRIPTS, CWD, MAIN_WT, repos)
    if log is not None:
        g["log"] = log


_SIG_MEMO = {}       # repo -> (watch generation, computed at, sig)
_SIG_SAFETY_AGE = 30.0


def model_sig():
    """model_sig, recomputed only when the stat watcher's generation moved (or every
    _SIG_SAFETY_AGE seconds as a net) — the pulse asks ~1/s and the extension every 2s, and
    on an unchanged repo neither needs the two spawns."""
    import time
    from . import watch
    repo = repo_cwd()
    gen = watch.generation(repo)
    hit = _SIG_MEMO.get(repo)
    if hit and hit[0] == gen and time.monotonic() - hit[1] < _SIG_SAFETY_AGE:
        return hit[2]
    sig = _model_sig_spawned()
    _SIG_MEMO[repo] = (gen, time.monotonic(), sig)
    return sig


def _model_sig_spawned():
    # cheap fingerprint of everything the model depends on: ref tips + config.
    # Changes on re-point, commit, or re-parent. Shared by /model (_mcache) and /sig —
    # hence it lives in ctx.
    # Deliberately NOT the RepoState fingerprint. This is a change detector, polled ~1/s by
    # the pulse and every 2s by the extension, and it only has to notice that the model moved:
    # local ref tips and the config file's mtime. Routing it through the
    # snapshot made it correct-but-expensive — a 165ms full read (2583 refs + 3427 parsed
    # config keys) every 2s, which under load 18 blew past the 1s timeout the --ensure reuse
    # check uses and had it start a SECOND server (2026-09-09). Remote drift is the pulse's
    # world_sig, not this.
    refs = run(["git", "for-each-ref", "--format=%(objectname)", "refs/heads"]).stdout
    gd = run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"]).stdout.strip()

    def mt(p):
        try:
            return os.path.getmtime(p)
        except OSError:
            return 0
    stamp = refs + str(mt(os.path.join(gd, "config")))
    return hashlib.sha1(stamp.encode()).hexdigest()
