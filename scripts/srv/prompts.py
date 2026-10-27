# srv/prompts.py — seed prompts for the Claude sessions the viewer ejects.


# The "reconcile" eject: a branch whose local history diverged from its pushed PR head
# (rewritten on one side — almost always a local rebase the pushed head hasn't caught). The
# session figures out the source of truth and reconciles WITHOUT force-pushing or blind-pulling.
def reconcile(branch, upstream, ahead, behind):
    return "\n".join([
        f"The local branch `{branch}` has DIVERGED from its pushed upstream `{upstream}`: "
        f"{ahead} commit(s) ahead and {behind} behind, so neither side fast-forwards.",
        "This is almost always because local was rebased or cleaned (onto a fresher main, or to "
        "absorb a rename) while the pushed PR head still carries the pre-rebase commits. Work out "
        "which side is the source of truth:",
        f"  • Read `git log --oneline {upstream}..{branch}` (local-only) and "
        f"`git log --oneline {branch}..{upstream}` (on the pushed head only).",
        "  • If the upstream's commits are just the stale ancestors of local's rewritten work, "
        "there is nothing to merge — local already wins. Say so and stop.",
        "  • Only if the upstream holds genuinely-new work local lacks, bring it over by "
        "rebasing/cherry-picking it onto local.",
        "Do NOT force-push and do NOT pull/merge the upstream in (that drags the stale commits "
        "back) — publishing is mine. When done, tell me in one line: was local already correct, "
        "or what did you carry over?",
    ])
