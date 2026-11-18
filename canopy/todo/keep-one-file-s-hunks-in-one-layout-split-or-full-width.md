+++
title = "Keep one file's hunks in one layout, split or full width"
kind = "fix"
state = "open"
area = "review"
size = "S"
why = "it can hide an addition: a file with an edit hunk (split) and an additions-only hunk (full width) switches layout mid-file, so the added line reads as if it had no old side to compare"
incarnation = "i_2a50393ef81341c4923fd0e6079df66e"
created = "2026-11-17"
updated = "2026-11-17"
+++

From Phil, 2026-11-17, on record-the-banned-word-activity-first, `lib/safety-checks/staticEmailContentCheck.ts` (+2 −1): the hunk at 81–87 (line 84 rewritten) is drawn side by side, and the hunk at 91–97 (line 94 added, nothing removed) is drawn full width, with no old column. Reading down the file, the layout flips at a hunk boundary and the added line loses its place against the old code.

Related: `a-file-with-only-additions-shows-one-column-not-an-empty-lef` (done 2026-11-08, 93766c3c) made the column choice by content: del == 0 → one column. That rule is right per FILE; here it (or a sibling) is being applied per HUNK.

**Worse case, same shape (2026-11-17, from the disable-evidence session):** on `/v2/b/loops/cite-what-ses-saw`, `jobs/ses-tenant-events.ts`, the hunk `@@ -84,6 +91,7 @@` adds one line (`+ recordSuspiciousActivity: SuspiciousActivityQueries.create,`, new line 94, inside `defaultDeps`) and removes nothing; the file has deletions in other hunks. The split view drew the added line in the LEFT (old) column with old-side numbering and no added marker, so it read as unchanged context and Phil couldn't see the dep being added (`git diff record-the-banned-word-activity-first...cite-what-ses-saw -- jobs/ses-tenant-events.ts`). So the per-hunk path doesn't just flip layout: it can render an addition as context. This makes the item a correctness bug for review, not polish.

## Next steps
1. Find where the diff view decides a hunk's columns (`oldHalfWidth` and its callers) and make the decision once per file: a file with any deletion is split for every hunk; only a file with no deletions at all goes full width.
2. In a split file, an additions-only hunk keeps an old column, blank beside the added lines and showing the unchanged context lines on both sides.
3. Test: a file with one edit hunk and one additions-only hunk lays out every hunk split, every added line is on the new side with new-side numbering and the added marker (the ses-tenant-events.ts shape as a fixture), and a file with only additions stays one column.
