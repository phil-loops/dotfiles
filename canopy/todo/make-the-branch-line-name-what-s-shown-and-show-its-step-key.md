+++
title = "Make the branch line name what's shown and show its step keys"
kind = "fix"
state = "open"
area = "review"
size = "S"
why = "the stretch's start dot is bright like a pick, '1 of 2 commits' doesn't say which, and the strip shows only , h — not ] h / [ h or C-o"
created = "2026-11-17"
updated = "2026-11-17"
+++

From Phil, 2026-11-17 ("idk if i understand how to use this and what the keyboard shortcuts are or should be"), on cite-the-openai-checks-activity showing one commit of two.

## Next steps
1. `BranchLine` (`ReviewPage.swift`): draw the stretch's start (`isStart`) as a hollow ring, not ink — only lit points should look chosen.
2. `ReviewLine.words`: for a one-commit part, name the commit — "`7a255a7` · <subject> — 2 of 2" instead of "1 of 2 commits".
3. The trailing hint follows the stretch: on part of the branch `[h ]h · C-o all`; on the whole branch `]h step commits`. `, h` (pick two ends) stays in the key sheet.
4. Tests on `ReviewLine.words` for the named commit, and on the hint per cover.
