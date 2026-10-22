# srv/checkout.py — the primary checkout and worktree prep.
#   GET  /head      the branch the main checkout currently points at (jump-to-checkout)
#   POST /prepare   prefetch: build a branch's worktree in the background
import os
import json

from . import ctx

# repo -> primary worktree path. A repo's PRIMARY worktree can't move while the server
# lives, but `git worktree list` walks every linked tree to answer (~200ms at 227
# worktrees in loops) — and /head is polled, so it paid that on every poll.
_main_wt_cache = {}


def _active_main_wt():
    # The PRIMARY worktree of the request's ACTIVE repo — git lists the main worktree first,
    # even when run from a linked one, and ctx.run's cwd is the pinned repo (the /<repo>/ path
    # prefix). NOT the global ctx.MAIN_WT, which is always the launched repo (loops) → a monotoad
    # checkout-here would otherwise run `git -C <loops> checkout <monotoad-branch>` and fail.
    repo = ctx.repo_cwd()
    hit = _main_wt_cache.get(repo)
    if hit:
        return hit
    for line in ctx.run(["git", "worktree", "list", "--porcelain"]).stdout.splitlines():
        if line.startswith("worktree "):
            _main_wt_cache[repo] = line[len("worktree "):]
            return _main_wt_cache[repo]
    return ctx.MAIN_WT


def head(req):
    req._send(200, json.dumps(
        {"branch": ctx.run(["git", "-C", _active_main_wt(), "rev-parse", "--abbrev-ref", "HEAD"]).stdout.strip()}))


def prepare(req, raw):
    d = json.loads(raw or "{}")
    ctx.fire([os.path.join(ctx.SCRIPTS, "stack-open"), "--prepare", d.get("branch", "")], cwd=ctx.CWD)
    req._send(200, '{"ok":true}')
