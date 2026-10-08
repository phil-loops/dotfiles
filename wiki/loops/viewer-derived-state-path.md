---
title: Getting there without a bounce
section: Viewer
order: 15
project: viewer-derived-state
lede: Eleven steps in dependency order, which is not the order of apparent risk. Making stack-forest a library feels like the scary step and is actually the safest; read sets feel like the keystone and must come last.
---

Target: [[viewer-derived-state-mechanism]]. Exit tests: [[viewer-derived-state-done]].

**Kill switch first.** Every structural step ships behind `STACK_ORACLE=0`, so a bad step is
disabled by an env flip and a re-exec, never by reverting a file while another session's gates
are mid-run. Nothing here needs a bounce — the watcher re-execs on `srv/*.py` mtime, same PID.
`stack-forest` is the **forest** lane: patch protocol.

0. **Harness and differential verifier** — a rerunnable bench, and a comparator diffing
   old-path against new-path payloads across every project. Content-compare
   `roots`/`children`/`requires` (unstable order), order-compare `mergeOrder`. Hook it to the
   pre-commit canopy harness so it cannot rot. **First, and not optional.**
1. **The palette's client bugs** — the `["model", project]` / `["model", repo, project]` key
   mismatch, the global index skipping the open forest while its model is absent, the missing
   `initialData`. Independent of everything; five lines.
2. **Capacity and the narrowed guard** — a byte-and-age budget for `_mcache`; the mid-build
   guard scoped to the forest's slice **plus its membership inputs**. Falsify by reproducing
   the 2026-07-21 freeze in a scratch project.
3. **`stack-forest` becomes importable** — hoist the module-level `argv` and dispatch into
   `main()`, CLI a thin wrapper, zero behaviour change. Verified byte-identical against the
   87-test harness. **This moved up from last:** until the builder is in-process, a recording
   view cannot see what the build reads, so every later step depends on it.
4. **The oracle** — refresher, single-flight, and the derived `parent → children` /
   `project → members` indexes. Pure addition, no reader changes.
5. **One membership function**, on those indexes, adopted by `stack-forest`,
   `/forest-branches`, `/model`, `/projects` — the server-side half of the palette's blindness.
6. **The builder reads through the oracle** — ~25 spawns become none. The latency win.
7. **Predicate read sets for `/model`** — now correct, because all reads flow through one
   recording view. Last, not first.
8. **Delta-aware pulse**; **9. epochs and "as of"**; **10. admission control**, claiming
   `background` through the existing `srv/gate_queue.py` so ambient work yields to a gates run.

1 and 2 land tonight. 0 gates everything. 3 is the unlock.
