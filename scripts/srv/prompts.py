# srv/prompts.py — the registry of seed prompts for every Claude touchpoint in the
# viewer. Centralised so the house style is edited in ONE place and every chat (the
# mail-map's Q&A rides /chat) speaks with one voice.
#
# HOUSE_STYLE points Claude at this repo's own CLAUDE.md conventions, so an answer
# lands at the bar Phil reviews to — not generic senior-engineer advice.


HOUSE_STYLE = (
    "Hold this repo's CLAUDE.md conventions as the bar when you judge the diff: comments "
    "default to zero (a comment must be misleading-without-it, never just nice-to-have); "
    "strict query → model → wiring layering; and the smallest change that leaves working "
    "code untouched. Call out where the diff drifts from these, not only generic issues."
)

# Read-only chats can look around but never touch the tree.
_REVIEW_VOICE = (
    "Answer concisely, in plain prose for a senior engineer. You may use Read/Grep/Glob "
    "to inspect related code, but you cannot and must not modify anything."
)


def file_chat(branch, path, patch, question):
    patch = (patch or "").strip()
    parts = [
        f"You're reviewing the file `{path}` on git branch `{branch}` of the Loops codebase.",
        HOUSE_STYLE,
        "Here is its diff against the branch's parent:",
        "",
        "```diff",
        patch or "(no textual diff was provided — read the file if you need its contents)",
        "```",
        "",
        _REVIEW_VOICE,
    ]
    if question:
        parts += ["", f"Question: {question}"]
    return "\n".join(parts)


def branch_chat(branch, patch, question):
    patch = (patch or "").strip()
    parts = [
        f"You're reviewing the whole git branch `{branch}` of the Loops codebase — "
        "every file it changes against its parent.",
        HOUSE_STYLE,
        "Here is the branch's combined diff:",
        "",
        "```diff",
        patch or "(no textual diff was provided — read the files if you need their contents)",
        "```",
        "",
        _REVIEW_VOICE,
    ]
    if question:
        parts += ["", f"Question: {question}"]
    return "\n".join(parts)


# Whole-forest chat: `seed` is the DAG gather chat.py builds (edge list + per-branch purpose/
# parent/requires/capped diff): pure read-only Q&A about how the feature hangs together.
def project_chat(project, seed, question):
    parts = [
        f"You're reviewing the entire `{project}` forest of the Loops codebase — every branch in "
        "the project and the DAG (parent + requires edges) that links them into one feature.",
        HOUSE_STYLE,
        "Here is the forest: an edge list first (so you see the shape), then each branch's purpose, "
        "parent, requires, and a capped diff:",
        "",
        seed,
        "",
        _REVIEW_VOICE,
        "Reason across the WHOLE feature — what it does end to end, where the gaps or unfinished "
        "seams are, what's left to build. Read individual files when a branch's capped diff isn't enough.",
    ]
    if question:
        parts += ["", f"Question: {question}"]
    return "\n".join(parts)


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
