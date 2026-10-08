---
title: What done looks like
section: Viewer
order: 16
project: viewer-derived-state
lede: Numbers the work must hit, derived from the 2026-10-07 baseline, plus the four properties that are easy to claim and must instead be proven.
---

Baseline: [[viewer-derived-state-measurements]]. Path: [[viewer-derived-state-path]].

**Latency**, on a machine under a gates run — the condition that produced the complaint, not
a quiet one:

| | baseline | target |
|---|---|---|
| `/model` cold (unopened forest) | 16–39s | < 1.5s |
| `/model` warm | 1.0–2.7s, no true hit | < 50ms |
| forest page, first content | 2.8–6.7s | < 1s |
| `/projects` on a forest page | 11.6s | off the critical path |
| palette items at first paint | 3 of 15 | all of them |

**Properties that must be proven, not asserted**

1. **A true cache hit is reachable and observable.** Today's failure was invisible because
   nothing reported hit rate — four requests in a row looked "warm" at 1–2.7s while every one
   of them rebuilt. Expose hits, misses and read-set invalidations per endpoint; a hit rate
   that silently falls to zero is the exact bug that shipped.
2. **Membership agrees everywhere.** For all ~157 projects, `/forest-branches` membership
   equals `/model`'s node set equals `stack-forest`'s. Assert it in the verifier, not by eye.
3. **A mid-build mutation is still caught.** Reproduce the 2026-07-21 contraction freeze and
   the phantom case — a branch created with `stack-parent` pointing into a forest mid-build —
   and assert both invalidate.
4. **Idle is still free.** The server reaps itself after 15 minutes precisely because ambient
   polling once cost 0.44s of CPU per minute for no reader. Measure spawns per minute with no
   tab open: it must stay zero.

**The honest negative result:** if cold `/model` lands under 1.5s and the hit rate holds, then
repo scale stopped mattering and the worktree sweep was never the fix. If it does not, the
sweep is the fix and this was the wrong tree. Decide that with step 6's number, not an opinion.
