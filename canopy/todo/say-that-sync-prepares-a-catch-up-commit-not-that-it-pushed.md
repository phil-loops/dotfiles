+++
title = "Say that sync prepares a catch-up commit, not that it pushed"
kind = "fix"
state = "open"
area = "review"
size = "S"
why = "'sync · carries it on top' reads like it pushed; it only prepares a local catch-up and the push is a separate step"
created = "2026-11-17"
updated = "2026-11-17"
+++

Seen 2026-11-17: the diverged line reads "diverged · ✗ <guard> · sync carries it on top" (`ShipStripView.swift`, the `b.diverged` branch of `line`). It reads as if sync pushes; sync only prepares a local catch-up commit and the push is a separate `p`.

## Next steps
1. Reword to name both steps, e.g. "sync catches it up locally · then p pushes".
2. Same words wherever else the sync hint appears (grep "carries it on top").
3. A test on the hint text so a later rewording keeps the push named as its own step.
