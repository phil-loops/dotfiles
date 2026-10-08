---
title: One oracle, read-set validity
section: Viewer
order: 13
project: viewer-derived-state
lede: The invariants the viewer's derived state should hold, and the shape that holds them. Nine hand-rolled caches collapse into one authority with an epoch and entries that know what they read.
---

Diagnosis: [[viewer-derived-state]]. Staging: [[viewer-derived-state-path]].

## Invariants

1. **Git is the only source of truth.** No durable index — a second store is a second
   staleness problem. Everything in memory, rebuildable from an empty process.
2. **Exactly one thing spawns git for state.** Reads go to the oracle; walks (`merge-base`,
   `rev-list --count`) still spawn, memoised per epoch.
3. **An entry is valid iff every input it actually read is unchanged.** Not a clock, not a
   repo-wide stamp, not a hand-listed key set that drifts from its reader.
4. **The library is the authority; the CLI is a wrapper.** `stack-forest` stays runnable by
   hand — that is why it exists — but the server imports it rather than shelling it.
5. **One function answers forest membership**, and every reader calls it.
6. **A payload carries the epoch it was computed at**, and a view rendering an older epoch
   says so. Stale-while-revalidate is honest or it is a lie the user acts on.
7. **A notification names what changed**; the client invalidates only what depends on it.
8. **Ambient work yields.** Idle must be free (already true, and why the server reaps itself);
   busy must stay responsive. Every endpoint single-flights, and polling stands down while a
   gates run holds the machine.
9. **Capacity is a byte-and-age budget**, never a count, and never a number correctness
   depends on.

Most likely to erode: 3. A read-set check is one line longer to write than a timestamp
comparison, and every future endpoint will be tempted by the timestamp.

## Non-goals

A persistent index. Incremental model builds — the payload is small and the cost is spawns,
not computation. Rewriting the client's query layer. And the worktree sweep: that is a lever
on the multiplier, and the point here is that the architecture stops being hostage to scale.
