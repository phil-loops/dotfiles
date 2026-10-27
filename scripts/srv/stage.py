# srv/stage.py — worktree reads shared by the push door: which worktree holds a branch, and
# whether its tracked files are dirty.
from . import ctx


def _worktrees():
    """[(path, branch-or-None)], main working tree first (git's order)."""
    wts, path, br = [], None, None
    for ln in ctx.run(["git", "worktree", "list", "--porcelain"]).stdout.splitlines():
        if ln.startswith("worktree "):
            if path:
                wts.append((path, br))
            path, br = ln[len("worktree "):], None
        elif ln.startswith("branch refs/heads/"):
            br = ln[len("branch refs/heads/"):]
    if path:
        wts.append((path, br))
    return wts


def _dirty(path):
    # tracked changes only — untracked files don't block a checkout
    return bool(ctx.run(["git", "--no-optional-locks", "-C", path, "status", "--porcelain", "-uno"]).stdout.strip())
