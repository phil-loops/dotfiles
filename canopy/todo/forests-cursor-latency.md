+++
title = "Find what still makes j/k on Forests take two frames"
kind = "look"
state = "open"
area = "perf"
size = "S"
why = "j/k is the most-used v2 key, and 33–36 ms p95 is twice its budget"
blocked_by = ["honest-command-timing"]
rank = 7
created = "2026-10-25"
updated = "2026-10-25"
+++

After honest timing lands, re-read `cursor.down/up`. Suspects: `warmSelected()` in `Forests.tsx` calls `page.warm` synchronously
inside the effect on every cursor move; `model.forests()` recomputing per move; the FLIP animation on `rows()`.
