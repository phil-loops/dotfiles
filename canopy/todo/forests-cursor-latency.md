+++
title = "Find what still makes j/k on Forests take two frames"
kind = "look"
state = "done"
area = "perf"
size = "S"
why = "j/k is the most-used v2 key, and 33–36 ms p95 is twice its budget"
blocked_by = ["honest-command-timing"]
created = "2026-10-25"
updated = "2026-11-02"
+++

After honest timing lands, re-read `cursor.down/up`. Suspects: `warmSelected()` in `Forests.tsx` calls `page.warm` synchronously
inside the effect on every cursor move; `model.forests()` recomputing per move; the FLIP animation on `rows()`.

## Done
2026-11-02 — native: forests() memoized per store change and cursor marks per list (e6cf522, 0d0779d); canopy --bench has j/k on the home and forest pages at 15–30ms. The Forests.tsx suspects went with the web viewer.
