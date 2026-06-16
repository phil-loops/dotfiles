# srv/ctx.py — shared state for the handler modules, injected ONCE by the main
# server at startup. Lets concern-specific handlers (restack, sync, picker, …) be
# lifted out of the stack-review-server.py monolith without threading run()/paths
# through every call — so concurrent sessions edit different files, not one giant one.
run = None      # run(argv) -> CompletedProcess, cwd=repo
ROOT = ""       # servedir (where restack.log / index.html live)
SCRIPTS = ""    # ~/.dotfiles/scripts
CWD = ""        # the repo the server was launched in
MAIN_WT = ""    # the repo's primary worktree (checkout-here / restack targets)


def init(*, run, ROOT, SCRIPTS, CWD, MAIN_WT):
    g = globals()
    g["run"], g["ROOT"], g["SCRIPTS"], g["CWD"], g["MAIN_WT"] = run, ROOT, SCRIPTS, CWD, MAIN_WT
