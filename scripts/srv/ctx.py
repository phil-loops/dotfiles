# srv/ctx.py — shared state for the handler modules, injected ONCE by the main
# server at startup. Lets concern-specific handlers (restack, sync, picker, …) be
# lifted out of the stack-review-server.py monolith without threading run()/paths
# through every call — so concurrent sessions edit different files, not one giant one.
import os
import hashlib
import threading

run = None      # run(argv, timeout=None) -> CompletedProcess, cwd=repo_cwd(); expiry = rc 124
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


def set_repo(path):
    _local.repo = path


def clear_repo():
    _local.repo = None


def repo_cwd():
    return getattr(_local, "repo", None) or CWD


def repo_path(name):
    # registry resolver: a viewer-repos name -> its main worktree, or None for an unknown name
    # (callers 400 rather than silently bind to the wrong repo).
    return REPOS.get(name)


def init(*, run, ROOT, SCRIPTS, CWD, MAIN_WT, repos):
    g = globals()
    g["run"], g["ROOT"], g["SCRIPTS"], g["CWD"], g["MAIN_WT"], g["REPOS"] = (
        run, ROOT, SCRIPTS, CWD, MAIN_WT, repos)


def model_sig():
    # cheap fingerprint of everything the model depends on: ref tips + config +
    # blessing ledger. Changes on re-point, commit, re-parent, or bless. Shared by
    # /model (_mcache), /projects (_pcache), and /sig — hence it lives in ctx.
    # the RepoState fingerprint: every ref (remotes too — origin moving is a change the page
    # should see), the local config's content, and the blessing ledgers' mtimes; re-read at
    # most every 2s, so the pulse's ~1/s reads cost one snapshot rebuild per 2s, not 2 spawns/s
    from . import repostate
    return repostate.snapshot().fingerprint
