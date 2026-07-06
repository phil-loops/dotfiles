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

## Open questions — settle 1 and 2 BEFORE the CI badge ships

1. **State precedence order (the principle contradicts its own guardrail).** "Every state
   has a face" collides with "one status signal per level" the moment a node is behind-main
   AND CI-red AND unseated — more states than slots (six chips per row was the original
   complaint). Decide the ranking once: each level shows only the single most
   action-relevant state — roughly *blocks-your-next-motion > will-ambush-later > FYI* —
   and the rest fold into hover. Without this, the CI badge is just chip number seven.
2. **Telemetry gates ACTIONS, not faces.** Applied literally, "under 1 use/day → ⋯" kills
   the CI badge (zero clicks, because it doesn't exist — invisible things can't be
   clicked). Faces are gated by ambush frequency: how often did this state silently burn a
   motion (the #9405 red-checks hunt = one incident). Actions stay click-gated.
3. **The Work-tab spine needs its own design pass.** "Lifecycle state + progress" names
   the shape, not the derivation: what are the canonical states
   (building → reviewing → shipping → contracting?), and what's each one's source of
   truth — blessing coverage, PR state, git config? Manual pips already failed BECAUSE
   manual. Deriving intent from observable state is the hard problem here; don't write UI
   until the states are enumerated with their sources.
4. **Cross-cutting state lives in a registry, not in per-request shell-outs.** CI truth
   comes from prwatch --sweep, dev-server truth from loops-restart's world. Follow the
   agent-registration precedent: pollers WRITE one file, the viewer only READS, and every
   badge carries a staleness timestamp — a green badge from 20 minutes ago on a now-red PR
   is its own ambush. A face that lies is worse than no face.
5. **Verdict-folding makes the restack button modal — keep the label contract.** As
   CONTRACT / dry-run-conflict / behind-N all fold into one button, "what will THIS click
   do" carries the whole safety story. Invariant: the button's label always states its
   plan (the ambient dry-run already does this); never just "restack."

## Decisions (Q1 + Q2 — settled 2026-07-05, header lane)

**Q1 — precedence is evaluated against the surface's NEXT MOTION, not globally.**
Adopted: `blocks-next-motion > will-ambush-later > FYI`, with the ranking anchored to
what each surface is FOR — the node view's motion is sync/push, a Home row's is
open/merge/review. Rules:

- A surface renders **at most one badge beyond its lifecycle chip**, and it comes from
  the highest non-empty level; everything below folds into the chip's reasons/hover
  (the spine already is that fold — this generalizes it).
- Ties within a level: the state whose motion is nearest wins (push-motion states over
  merge-motion over review-motion); then most-recent onset.
- **Marks are not badges**: a ≤2-glyph annotation riding the chip (±N dirt, the gold
  fill) is metadata and exempt from the slot — the slot is for standalone chrome.
- States PROMOTE with context: deploy-watch gap is FYI while editing, blocks at the
  door (the wards already encode this — a ward IS blocks-next-motion rendered at the
  moment of the motion; a badge is its preview).
- CI placement falls out: red-on-your-open-PR = ambush (it burns the merge you're
  walking toward), running = hover, green = silence. The badge competes for the one
  ambush slot instead of becoming chip #7 — most rows show nothing, which is the point.

**Q2 — adopted, with a symmetric death rule.** Actions are click-gated (the cliff);
faces are BORN by a named ambush-incident (dirty-sync → the ± tier; the #9405
red-checks hunt → the CI face) and DIE by never-ranking: a face that hasn't won its
slot anywhere for ~30 days demotes permanently to hover. And point 4's staleness rule
binds every face: past its freshness stamp it renders as stale-unknown, never as its
last value — a face that lies is worse than no face.
