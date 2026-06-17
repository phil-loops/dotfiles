# srv/ctx.py — shared state for the handler modules, injected ONCE by the main
# server at startup. Lets concern-specific handlers (restack, sync, picker, …) be
# lifted out of the stack-review-server.py monolith without threading run()/paths
# through every call — so concurrent sessions edit different files, not one giant one.
import os
import hashlib

run = None      # run(argv) -> CompletedProcess, cwd=repo
ROOT = ""       # servedir (where restack.log / index.html live)
SCRIPTS = ""    # ~/.dotfiles/scripts
CWD = ""        # the repo the server was launched in
MAIN_WT = ""    # the repo's primary worktree (checkout-here / restack targets)


def init(*, run, ROOT, SCRIPTS, CWD, MAIN_WT):
    g = globals()
    g["run"], g["ROOT"], g["SCRIPTS"], g["CWD"], g["MAIN_WT"] = run, ROOT, SCRIPTS, CWD, MAIN_WT


def model_sig():
    # cheap fingerprint of everything the model depends on: ref tips + config +
    # blessing ledger. Changes on re-point, commit, re-parent, or bless. Shared by
    # /model (_mcache), /projects (_pcache), and /sig — hence it lives in ctx.
    refs = run(["git", "for-each-ref", "--format=%(objectname)", "refs/heads"]).stdout
    gd = run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"]).stdout.strip()

    def mt(p):
        try:
            return os.path.getmtime(p)
        except OSError:
            return 0
    stamp = refs + str(mt(os.path.join(gd, "config"))) + str(mt(os.path.join(gd, "stack-blessed.json")))
    return hashlib.sha1(stamp.encode()).hexdigest()
