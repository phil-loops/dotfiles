+++
title = "Show push-ready's unapplied review findings on the v2 branch page"
kind = "build"
state = "open"
area = "review"
size = "S"
why = "the findings push-ready wasn't sure about sit next to the diff I'm reading instead of only in Claude's chat"
links = ["memory:project_push-ready-review-phase.md"]
created = "2026-10-25"
updated = "2026-10-25"
+++

push-ready writes uncertain findings as `branch.<b>.stack-review-flag` (multivar), valid only for `review-flags-tree`; `srv/push.py` reads them for the v1 door.
Neither `/state` nor the v2 review page carries them. Show them quietly, dropping once the tree moves.
