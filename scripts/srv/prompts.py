# srv/prompts.py — the registry of seed prompts for every Claude touchpoint in the
# viewer. Centralised so the house style is edited in ONE place and the read-only file
# chat, the whole-branch chat, and the select-to-Claude chip all speak with one voice.
#
# HOUSE_STYLE points Claude at this repo's own CLAUDE.md conventions, so an answer
# lands at the bar Phil reviews to — not generic senior-engineer advice.

import json
import os

from . import ctx

# The read-only chat stays read-only, but it can OFFER actions the viewer runs on a click.
# The menu lives in ONE file (viewer-solid/src/chat-actions.json) that the frontend also reads
# to dispatch the button — so what we teach here and what the click does can't drift.
_ACTIONS_PATH = os.path.join(
    os.path.dirname(__file__), "..", "viewer-solid", "src", "chat-actions.json"
)


def _load_actions():
    with open(_ACTIONS_PATH) as f:
        return json.load(f).get("actions", [])


# The paragraph that teaches Claude the action vocabulary, filtered to this chat's scope ("file"
# chats get file+branch actions; "branch" chats get branch-only). Returns "" when nothing applies,
# so a scope with no actions adds no noise.
def action_menu(scope):
    usable = [a for a in _load_actions() if a.get("scope") == "branch" or scope == "file"]
    if not usable:
        return ""
    lines = [
        "You can OFFER the user an action as a clickable button — this is how a suggestion of "
        "yours gets executed, since you yourself stay read-only. To offer one, emit a fenced code "
        "block whose language is `loops-action` holding a single JSON object: "
        '{"action": "<id>", "label": "<short button text>", "params": {...}}. '
        "Put it AFTER the prose that explains why. These are the ONLY actions — never invent an id:",
    ]
    for a in usable:
        ps = a.get("params", [])
        param_note = (
            " — params: " + ", ".join(f"{p['name']} ({p['desc']})" for p in ps) if ps else ""
        )
        lines.append(f"- `{a['id']}`: {a['describe']}{param_note}")
    lines.append(
        "Offer an action only when it is clearly the next step, at most two or three at once, and "
        "never fabricate one you're unsure applies. The user clicks to run it; you cannot run it."
    )
    return "\n".join(lines)


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


def _is_test(p):
    return ".test." in p or ".spec." in p or "__tests__/" in p or "/tests/" in p


# The branch's real state, so the model judges which actions apply from FACT rather than guessing off
# the diff — it's why set-purpose stops firing once a purpose exists. Cheap git reads via ctx.run (in
# the selected repo); any one failing just blanks its fact, never breaks the chat. Kept here rather
# than in chat.py so the whole action-relevance feature stays in one file the chat owns.
def branch_state(branch):
    def g(*args):
        try:
            return ctx.run(["git", *args]).stdout.strip()
        except Exception:
            return ""

    parent = g("config", f"stack-branch.{branch}.parent") or "main"
    names = [n for n in g("diff", "--name-only", f"{parent}...{branch}").splitlines() if n]
    dirs = {n.rsplit("/", 1)[0] if "/" in n else "." for n in names}
    purpose = g("config", f"branch.{branch}.description")
    return "\n".join([
        "Current branch state — judge which actions genuinely apply from THIS, not the diff alone; "
        "don't offer one the state already rules out:",
        f"  purpose: {chr(8220) + purpose + chr(8221) if purpose else '(none set — offering to set one makes sense)'}",
        f"  commits on branch: {g('rev-list', '--count', f'{parent}..{branch}') or '?'}",
        f"  behind origin/main: {g('rev-list', '--count', f'{branch}..origin/main') or '?'} commit(s)",
        f"  files changed: {len(names)} across {len(dirs)} dir(s)",
        f"  tests touched by this branch: {'yes' if any(_is_test(n) for n in names) else 'none'}",
    ])


def file_chat(branch, path, patch, question):
    patch = (patch or "").strip()
    return "\n".join([
        f"You're reviewing the file `{path}` on git branch `{branch}` of the Loops codebase.",
        HOUSE_STYLE,
        "Here is its diff against the branch's parent:",
        "",
        "```diff",
        patch or "(no textual diff was provided — read the file if you need its contents)",
        "```",
        "",
        _REVIEW_VOICE,
        branch_state(branch),
        action_menu("file"),
        "",
        f"Question: {question}",
    ])


def branch_chat(branch, patch, question):
    patch = (patch or "").strip()
    return "\n".join([
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
        branch_state(branch),
        action_menu("branch"),
        "",
        f"Question: {question}",
    ])


# Whole-forest chat: `seed` is the DAG gather chat.py builds (edge list + per-branch purpose/
# parent/requires/capped diff). No action menu — the per-branch verbs need a single branch; at
# project altitude the chat is pure read-only Q&A about how the feature hangs together.
def project_chat(project, seed, question):
    return "\n".join([
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
        "",
        f"Question: {question}",
    ])


# Dropped/pasted screenshots ride in as saved temp files — headless claude can't take image
# input directly, but Read renders an image visually, so we just point it at the paths.
def with_attachments(prompt, paths):
    if not paths:
        return prompt
    return "\n".join([
        prompt,
        "",
        f"I attached {len(paths)} image(s) — Read each path to see it:",
        *[f"- {p}" for p in paths],
    ])


# The select-to-Claude chip fires a FULL (editing) claude in the worktree, so it gets the
# house style as an editing bar — no read-only clause.
def select_assist(branch, selection_lines, instruction):
    lines = [
        f"You're in a worktree of branch `{branch}`. I selected these spots in its diff:",
        *selection_lines,
        "",
        HOUSE_STYLE,
        "",
        instruction.strip() or "Review these and tell me what you'd improve.",
    ]
    return "\n".join(lines)


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
