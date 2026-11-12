# srv/stackcfg.py — the ONE place the server writes per-branch stack config:
# `branch.<b>.stack-<key>`, so git GCs it when the branch is deleted and carries it on rename.
#
# This is where the namespace migration from `stack-branch.<b>.<key>` ended (design-stack-config-
# namespace.md): writers went target-only on 2026-11-09, every repo was swept, and on 2026-11-12
# the readers dropped their fallback arm. One spelling, read and written here and in
# RepoState.branch_key.
from . import ctx, repostate


def _key(branch, key):
    return f"branch.{branch}.stack-{key}"


def set_key(branch, key, value):
    ctx.run(["git", "config", _key(branch, key), str(value)])
    repostate.invalidate()


def add_key(branch, key, value):
    ctx.run(["git", "config", "--add", _key(branch, key), str(value)])
    repostate.invalidate()


def unset_key(branch, key, value_regex=None):
    ctx.run(["git", "config", "--unset", _key(branch, key)] + ([value_regex] if value_regex else []))
    repostate.invalidate()


def unset_all(branch, key):
    """Drop every value of a multivar — `--unset` refuses when more than one value is set, so a
    rewritten list needs this before it is re-added."""
    ctx.run(["git", "config", "--unset-all", _key(branch, key)])
    repostate.invalidate()


def remove_stack_section(branch):
    """Every stack key for a branch, unset KEY BY KEY on purpose: `--remove-section branch.<b>`
    would take git's own branch.<b>.remote / .merge / .description with it. (After a `branch -D`
    git has already GC'd these — the whole point of the namespace.)"""
    out = ctx.run(["git", "config", "--get-regexp", rf"^branch\.{branch}\.stack-"]).stdout
    for ln in out.splitlines():
        k = ln.split(" ", 1)[0]
        if k:
            ctx.run(["git", "config", "--unset-all", k])
    repostate.invalidate()
