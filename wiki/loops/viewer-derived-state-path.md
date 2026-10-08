---
title: Getting there without a bounce
section: Viewer
order: 15
project: viewer-derived-state
lede: Ten steps, each independently revertible, independently valuable, and verified before the next. The verifier comes first because every later safety argument is "the verifier says identical".
---

Target: [[viewer-derived-state-mechanism]]. Baseline:
[[viewer-derived-state-measurements]]. Nothing here needs a bounce — the watcher re-execs on
any `srv/*.py` mtime change, same PID. `stack-forest` is the **forest** lane: step 5 goes
through the patch protocol.

0. **The harness and the differential verifier** — a rerunnable bench, and a comparator
   diffing old-path against new-path payloads across every project. Content-compare
   `roots`/`children`/`requires` (unstable order) and order-compare `mergeOrder`, whose order
   is its meaning. **Not optional, and first.**
1. **The palette's own bugs**, independent of all this and what was actually hit: the
   `["model", project]` / `["model", repo, project]` key mismatch, the global index skipping
   the open forest while its model is absent, the missing `initialData`. Five lines.
2. **Capacity and the guard** — a byte-and-age budget for `_mcache`; the mid-build guard
   narrowed to the forest's own slice **plus its membership inputs**, a down payment on the
   read set. Falsify by reproducing the freeze in a scratch project.
3. **The oracle's refresher and single-flight** — pure addition. Verify `/sig` and pulse
   semantics unchanged; count spawns per minute with a tab open.
4. **Read-set caching, applied to `/model` alone** — the keystone; the rest repeats it.
5. **`stack-forest` becomes a library** — (a) importable, CLI a thin wrapper, byte-identical
   against the 87-test harness; (b) git reads swapped for oracle reads. The real win.
6. **One membership function**, `/forest-branches` onto it — verify its membership equals
   `/model`'s node set across ~157 projects.
7. **Delta-aware pulse** — count requests per tick during a commit storm.
8. **Epochs on the wire**, and an "as of" marker on any view rendering a stale epoch.
9. **Admission control** — rerun the harness *during* a gates run; p95 should stop tracking
   load average.

1 and 2 land tonight; 0 gates everything after; 5 comes last of the structural moves.
