---
title: One model of the words that land
section: Viewer redesign
order: 42
project: viewer-redesign
lede: Only the PR title and body reach main. Today five surfaces each derive "what this branch does" differently, the title has no editor, and most edits delete body text that goes nowhere.
---

**The model: three strings, each with one home**

| String | Who writes it | Lands where |
|---|---|---|
| Description: one line per branch | Phil or Claude, editable inline wherever it's shown | Seeds everything else; read-only elsewhere |
| Outline: 1–4 commit subjects, body only for a non-obvious why | Claude drafts, Phil edits | The reviewer's story |
| PR title + body | Drafted in the viewer from the two above | The squash commit on main |

Stories fold into the description. Commit bodies stop carrying the baked "Part of a stack" block; the PR body has it.

**The outline editor**

- One editor per branch: every one of its own commits as a row (subject plus an optional why line), each beside its own diff.
- Save writes every changed row in one `stack-reword` pass, then reseats children in the background with a visible status.
- A commit is editable whenever it isn't on any remote, the same guard `stack-reword` already enforces. The two UI gates that block 65% of branches go.
- Inline hints, never blocking:
  - a subject over 50 characters;
  - the scope filled from the forest's ticket, in lowercase;
  - follow-up commits written bare, without the opening commit's type and scope.
- Every change is journaled with undo; refusals show in place.

**Landing text**

- The PR title becomes a real field, prefilled from the opening commit.
- The compare link passes both `&title=` and `&body=`.
- After the PR exists, show it read-only, with "edit on GitHub".
