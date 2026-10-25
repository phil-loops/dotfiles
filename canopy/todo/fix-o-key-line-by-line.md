+++
title = "Fix o opening Helix at the wrong place in the line-by-line diff"
kind = "fix"
state = "open"
area = "review"
size = "S"
why = "o is the most-used reading key; landing on the wrong line breaks the jump to types"
links = ["memory:project_canopy-v2.md"]
created = "2026-10-25"
updated = "2026-10-25"
+++

v2 review page, line-by-line (unified) diff view: `review.open` in `v2/commands/review.ts` sends `sideLine(h.row).line` to `/open`.
In that view the row's side/line mapping lands Helix somewhere else; split view is the reference to compare against.
