+++
title = "Keep one file's hunks in one layout, split or full width"
kind = "fix"
state = "open"
area = "review"
size = "S"
why = "a file with an edit hunk (split) and an additions-only hunk (full width) switches layout mid-file, so the added line reads as if it had no old side to compare"
incarnation = "i_2a50393ef81341c4923fd0e6079df66e"
created = "2026-11-17"
updated = "2026-11-17"
+++

From Phil, 2026-11-17, on record-the-banned-word-activity-first, `lib/safety-checks/staticEmailContentCheck.ts` (+2 −1): the hunk at 81–87 (line 84 rewritten) is drawn side by side, and the hunk at 91–97 (line 94 added, nothing removed) is drawn full width, with no old column. Reading down the file, the layout flips at a hunk boundary and the added line loses its place against the old code.

Related: `a-file-with-only-additions-shows-one-column-not-an-empty-lef` (done 2026-11-08, 93766c3c) made the column choice by content: del == 0 → one column. That rule is right per FILE; here it (or a sibling) is being applied per HUNK.

## Next steps
1. Find where the diff view decides a hunk's columns (`oldHalfWidth` and its callers) and make the decision once per file: a file with any deletion is split for every hunk; only a file with no deletions at all goes full width.
2. In a split file, an additions-only hunk keeps an old column, blank beside the added lines and showing the unchanged context lines on both sides.
3. Test: a file with one edit hunk and one additions-only hunk lays out every hunk split, and a file with only additions stays one column.
