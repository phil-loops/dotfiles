---
title: Getting there without a bounce
section: Viewer
order: 15
project: viewer-derived-state
lede: Twelve steps in dependency order, which keeps turning out not to be the order of apparent risk. Domain routing moved from eighth to third; read sets moved from first to ninth, behind a prerequisite nobody would guess.
---

Target: [[viewer-derived-state-mechanism]]. Exit tests: [[viewer-derived-state-done]].

**Kill switch first.** Every structural step ships behind `STACK_ORACLE=0`, so a bad step dies
by an env flip and a re-exec, never by reverting a file while another session's gates are
mid-run. Nothing needs a bounce — the watcher re-execs on `srv/*.py` mtime, same PID.
`stack-forest` is the **forest** lane: patch protocol.

0. **Harness and differential verifier** — a bench, and a comparator diffing old against new
   payloads across every project. Content-compare `roots`/`children`/`requires`, order-compare
   `mergeOrder`. Hooked to the pre-commit canopy harness so it cannot rot. **First.**
1. **The palette's client bugs** — the query-key mismatch, the global index skipping the open
   forest while its model is absent, the missing `initialData`. Five lines.
2. **Capacity and the narrowed guard** — byte-and-age budget for `_mcache`; the mid-build
   guard scoped to the forest's slice plus its membership inputs.
3. **Domain routing on the wire** ([[viewer-derived-state-domains]]) — one event per domain
   instead of `sig` and `world` sharing `update`. **Moved up from eighth:** it is ~6 lines,
   needs none of the oracle, and removes most of the twenty-key fan-out that was making the
   machine contended in the first place.
4. **`stack-forest` becomes importable** — hoist module-level `argv` into `main()`, CLI a thin
   wrapper, byte-identical against the 87-test harness. Nothing below can see the build's
   reads until this lands.
5. **The oracle** — refresher, single-flight, derived `parent → children` / `project → members`
   indexes. Pure addition.
6. **One membership function** on those indexes, adopted by every reader.
7. **Dirt leaves the payload** — `git status` output becomes a serve-time overlay on the
   `_overlay_live` pattern, keyed on each worktree's `.git/index` mtime. **A prerequisite for
   9**, not a nicety: while the payload carries filesystem state no read set can validate it.
8. **The builder reads through the oracle** — ~25 spawns become none. The latency win.
9. **Predicate read sets for `/model`.** Last of the core work, not first.
10. **Epochs and "as of"**; **11. admission control**, claiming `background` through the
    existing `srv/gate_queue.py`.
12. *Optional:* per-slice deltas — which forest moved. Only if 3 left something on the table.

**Tonight: 1, 2 and 3.** 0 gates everything. 4 is the unlock; 7 is the one that would have
been found at step 9, painfully.
