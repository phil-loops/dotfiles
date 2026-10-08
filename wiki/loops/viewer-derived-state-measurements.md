---
title: What the viewer cost on 2026-10-07
section: Viewer
order: 12
project: viewer-derived-state
lede: The baseline the derived-state work is measured against, taken under a live load storm and again while the machine was quiet, so the structural cost and the contention multiplier are separable.
---

Diagnosis: [[viewer-derived-state]]. Access log `~/.cache/canopy-server/agent.err.log`.

**Scale.** 307 worktrees, 1,564 branches, a 7,969-line `.git/config` (July's sweep left
159/918). Spawn floor **34ms**; `worktree list --porcelain` **2.19s** against 100–220ms in
July, with ~15 callers in `srv/`.

**Contention, not computation.** p50 two hours apart: `/node` 815ms → 5,659ms, `/projects`
798ms → 7,745ms, `/previews` 2,474ms → **29,397ms**. Concurrent: another session's gates,
a `cp -cR node_modules` pool copy, OrbStack at 72%, load 8.2 on 10 cores. During a 15s cold
`/model` the server burned **0.35s of CPU** — it waits on children. Of one 32.7s request,
`stack-forest` held the process table **3.4s**; from a shell it takes 0.75–1.6s.

**The model cache.** Unopened forests cost **16–39s** cold. Warm one, visit 9 others, return:
**1.9s → 20.9s** (`_MCACHE_MAX = 8`, ~157 forests). It never reaches a true hit — four
consecutive requests, nothing changing: **38.7, 2.66, 1.60, 1.06s**, where a true hit is
~10ms. `_build` voids the sig when `ctx.model_sig()` moves mid-build, so **the slower a forest
builds, the less likely it can ever cache**. A never-seen forest skips stale-while-revalidate
entirely and blocks for the whole build: the long "loading…".

**The page and the fan-out.** Cold client: first content **2.8s** and **6.7s** over two runs;
`/projects` cost **11.6s on the same load**, fetched only for NavRail's count. ~75 pulse
fan-outs in the hour, one every 48s, each ~12s plus `/previews` at 29s — the next tick lands
before the last finishes.

**The palette.** 23:36:32 ⌘K → 23:48–23:49 the four branches created → 23:53:27 ⌘K again →
23:53:28 `/forest-branches` 629ms → 23:54:25 the entry appears. Dark ~58s, fixed itself with
no reload. At first paint the open forest had **3 palette items; 15 six seconds later.**
