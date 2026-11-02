+++
title = "Bench a big synthetic forest and diff"
kind = "look"
state = "open"
area = "perf"
size = "M"
why = "today's data is too small to show work that rebuilds everything on each change — the 3s diff rebuild only showed on the one big PR"
created = "2026-11-02"
updated = "2026-11-02"
+++

Generate a local-only store: a few hundred branches across a dozen forests and a review with thousands of changed lines. Then run every bench pass on it.

## Next steps
- `--bench --synthetic N`: hydrate the store from a generated snapshot (no server), and serve a generated payload for one review.
- Find the first key that crosses budget as N grows, and fix the thing that scales.
