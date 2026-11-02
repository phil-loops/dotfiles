+++
title = "Time cold start, first page visits and window resize"
kind = "look"
state = "open"
area = "perf"
size = "S"
why = "nothing measures them, and the first : on a page measured 256ms under load"
created = "2026-11-02"
updated = "2026-11-02"
+++

## Next steps
- Bench pass: launch to first frame, first visit to every page, and the first open of each overlay, before anything is warm.
- Resize the window between two sizes on a big review, then time the layout.
