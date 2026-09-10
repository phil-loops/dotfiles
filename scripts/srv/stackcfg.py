# srv/stackcfg.py — the ONE place the server writes per-branch stack config, and the reason it
# exists is the namespace migration: `stack-branch.<b>.<key>` (legacy) → `branch.<b>.stack-<key>`
# (target, so git GCs it when the branch is deleted and carries it on rename).
#
# Phase 2 of that migration was written as "sweep every key and flip every writer in one
# window", which across ~100 write sites in files several sessions hold is a coordination
# problem with no good moment. Dual-writing removes the window: every writer emits BOTH
# spellings, readers already prefer the target, and the sweep then becomes idempotent and
# runnable at any time. What made the ordering matter is the failure mode of getting it wrong —
# after a sweep, a writer still emitting only the legacy spelling is SILENTLY SHADOWED, because
# readers take the target. A re-parent would report success and do nothing.
#
# So: route writes through here, and dropping the legacy spelling later is one edit in one file
# rather than a hundred.
from . import ctx, repostate


def _pair(branch, key):
    """(target, legacy) — target first, matching the read precedence in RepoState.branch_key."""
    return f"branch.{branch}.stack-{key}", f"stack-branch.{branch}.{key}"


def set_key(branch, key, value):
    for k in _pair(branch, key):
        ctx.run(["git", "config", k, str(value)])
    repostate.invalidate()


def add_key(branch, key, value):
    for k in _pair(branch, key):
        ctx.run(["git", "config", "--add", k, str(value)])
    repostate.invalidate()


def unset_key(branch, key, value_regex=None):
    for k in _pair(branch, key):
        ctx.run(["git", "config", "--unset", k] + ([value_regex] if value_regex else []))
    repostate.invalidate()


def remove_stack_section(branch):
    """Every stack key for a branch, both spellings. The target side is unset KEY BY KEY on
    purpose: `--remove-section branch.<b>` would take git's own branch.<b>.remote / .merge /
    .description with it. (After a `branch -D` git has already GC'd the target keys — which is
    the whole point of the migration — so this is usually the legacy section alone.)"""
    out = ctx.run(["git", "config", "--get-regexp", rf"^branch\.{branch}\.stack-"]).stdout
    for ln in out.splitlines():
        k = ln.split(" ", 1)[0]
        if k:
            ctx.run(["git", "config", "--unset-all", k])
    ctx.run(["git", "config", "--remove-section", f"stack-branch.{branch}"])
    repostate.invalidate()
