+++
title = "Fix o opening Helix at the wrong place in the line-by-line diff"
kind = "fix"
state = "open"
area = "review"
size = "S"
why = "o is the most-used reading key; landing on the wrong line breaks the jump to types"
links = ["memory:project_canopy-v2.md"]
rank = 3
created = "2026-10-25"
updated = "2026-10-25"
+++

v2 review page, line-by-line (unified) diff view: `review.open` in `v2/commands/review.ts` sends `sideLine(h.row).line` to `/open`.
In that view the row's side/line mapping lands Helix somewhere else; split view is the reference to compare against.

## Next steps
Design: *One source of truth* — Helix opens the branch's file, so `o` must always send a line of the new file. `sideLine` answers a different question (where a comment anchors) and returns the OLD line for a deleted row; in line-by-line view every `-` row is one of those, which is the likely bug (unconfirmed — reproduce first).
1. Reproduce: on a v2 review page, unified view, put the cursor on a `-` line and press `o`; Helix lands on the old line number in the new file.
2. `review/diff.ts` — pure `newLineAt(rows, i)`: the row's new line; for a deleted row, the next row's new line in the same hunk, else the previous one's + 1. Test first in `review.test.ts` (del run at hunk end, del at file end, pure-deletion file → 1).
3. `commands/review.ts` `review.open` — use `newLineAt` for `h.kind === "line"`; threads keep `local.line` (already new-side).
4. Same check for split view's pure-deletion rows (they share the bug).
Verify: npm test; Puppeteer is no help here (Helix) — check `/open`'s body in the server log (`reqlog`) for a `-` row.
Done when: `o` on any row lands on that spot in the branch's file.
