---
title: Where R&D pays
section: Viewer redesign
order: 44
project: viewer-redesign
lede: Three bets on the 75% of PR time spent before review, each cheap to trial on a few forests. Not more polish on messages, gates or review rounds; there's no headroom there.
---

**Bet 1: open the whole forest at once.** Of 203 forest PRs, 108 opened only after a sibling merged. Opening every node together, stacked with `Stacked on: #N` bases, would overlap the roughly 15-hour review cycles instead of chaining them.

- The viewer already knows parents and merge order; this is one outbox action.
- Trial: three forests. Measure first-open → last-merge span against the 164-hour median.

**Bet 2: push before three.** A PR opened at or after 15:00 PT takes 18.8 h to merge, against 3.2 h before.

- Show the time-of-day cost in the outbox.
- Offer a "queue for 9am" push that opens PRs and requests review in the morning.
- Trial: alternate weeks.

**Bet 3: merge the approved chain.** The approval → merge tail has a p90 of 78 h, because children wait on parents.

- Auto-merge a child when its parent lands and it's approved and green.
- Measure approved-but-unmerged hours per forest.

**Not worth it, on this data:** fewer review rounds (about 98% pass first time), PR-body polish, commit-message quality, and faster gates (push to PR already takes about 0 minutes).

**Do first, because every bet needs it:** fix the holes in [[viewer-redesign-evidence]].

- Stamp every call with who made it.
- Track map clicks.
- Log refusals.
- Revive the push event.
- Dedupe replayed commits.
- Keep the request log for 90 days, minus extension polling.
