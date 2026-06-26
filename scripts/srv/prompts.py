# srv/prompts.py — the registry of seed prompts for every Claude touchpoint in the
# viewer. Centralised so the house style is edited in ONE place and the read-only file
# chat, the whole-branch chat, and the select-to-Claude chip all speak with one voice.
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
