# Holistic legibility — the lifecycle audit brief

*2026-07-05 · from Phil via the gh-to-nvim session · for the viewer lane's next arc*

## The principle (your own words)

> The shared-state chip made "what does the team see" legible, and this makes "what does
> git not yet see" legible — after which every kind of local state has a face in the UI,
> and nothing can ambush a motion silently.

That's the north star. The corollary that keeps it clean: **states get faces; motions get
ONE button; everything else is keys/⌘K/⋯.** Faces are badges and chips — never actions.

## The method change this brief asks for

The de-clutter arc worked, but it ran on screenshots: Phil photographs a surface, we trim
it. We named that the anti-pattern and kept doing it. The holistic method: **walk the
lifecycle end to end, list every state that can ambush a motion, check each has a face,
rank the fixes by stack-usage** — then build in that order, not screenshot order.

Lifecycle: build → review → ship → merge → contract → observe.

## Audit result: where the principle already holds

- **Review** (his heaviest surface by telemetry: chat 89 / open 78 / bless 44 per 10d) —
  blessing ledger, since-blessed deltas, chat presence ✦, drawer-docks-to-pill, keys over
  buttons. The most-used surface is the most polished. Correct.
- **Ship** — prep header (seven things), shared-state chip, FF-only push door. Coherent.
- **Drift** — off-parent pill + scoped reseat, behind-main count, parked-restack popover.

## The gaps, ranked by how often they bite

1. **CI state has no face.** Today's failing-test hunt on #9405 started from a GitHub
   email — the viewer showed a happy approved node while its checks were red. PR badges
   already render on rows/nodes; they just don't know about checks. `gh pr checks` /
   `gh run view` are cheap and cacheable (see `prwatch --sweep`, which already polls —
   the DATA exists on the machine, it just never reaches a badge). Red checks on the node
   a reviewer is blessing is the definition of ambush.
2. **"What should I do now."** The Work/NEXT tab is still the tier-ranked bolt-on Phil
   flagged weeks ago (memory: feedback_viewer-home-priority-bolt-on — wants lifecycle
   state + a progress spine, not more tiers). Most intent-central surface, least
   optimized. The de-clutter arc trimmed chrome everywhere but never rebuilt this ranking.
3. **Post-merge ghost → CONTRACT badge.** Already in flight (per the earlier note):
   passive, computed on page load via rebase-classify exit-20; the action folds into the
   one ambient restack button like the dry-run verdict did. No new buttons.
4. **"What is :3000 serving?"** Stage moves the main checkout; loops-tail gives ears;
   but no surface says "dev = goal-lock tip, 2 commits stale." One Hearth chip
   (branch + ahead/behind of its own tip) completes the stage feature's loop.
5. **Multi-repo** — spec'd (design-multirepo-forests.md), unbuilt. Fine until it isn't;
   stays ranked last by usage.

## Guardrails (so this arc doesn't re-clutter)

- Telemetry before affordances: anything under ~1 use/day starts life in ⋯/⌘K, not a row.
- New STATE → badge/chip only. If a badge seems to need its own button, fold the action
  into the existing motion's button (restack precedent) or a key.
- One status signal per level (Home row → forest map → node header) — no chip stacking.
- When Phil says "too many X," run stack-usage first, then trim holistically, not per-shot.

*Items 1–2 are where the next effort goes. 3 is yours already. 4 is small. 5 waits.*
