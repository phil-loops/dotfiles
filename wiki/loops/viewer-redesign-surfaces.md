---
title: Three surfaces, and what goes
section: Viewer redesign
order: 43
project: viewer-redesign
lede: Keep what the loop uses — read a node, fix the words, push, jump. Turn the map into an overlay and the home page into an outbox. Cut what four months never touched.
---

**1. The outbox (home).** Every branch that's ready, grouped by forest in merge order. Each row shows the gates verdict, landing title, PR state and "approved, waiting on parent". Actions:

- push one branch, or open the whole forest (see [[viewer-redesign-rnd]]);
- edit the landing text inline (see [[viewer-redesign-landing-text]]).

It replaces the Work tab, the forest overview page and the push door.

**2. The node.** The diff for reading (where dwell actually happens) plus the outline editor in a right-hand column. The description sits editable at the top. Gates and prep are status, not buttons; `/push-ready` owns them now.

**3. The map, as an overlay.** `m` toggles it over whatever you're on; clicking a node jumps there. It stays the navigation loop it already is, minus the round trip through a separate page. The palette stays as a branch finder.

**Cut or fold, with evidence**

| Item | Uses in four months |
|---|---|
| Triage tiers, standalone, review import, wiki chat, purpose and plan editors | ~0 |
| Merge-story face | folds into the outbox; its derived lines contradict real subjects |
| j/k spine walk and 1–4 diff-base keys | 12 and 7 presses |
| Contract and checkout buttons | 43% and 24% failure rates; contraction is automatic for focus forests now |

**Keep, unmeasured:** the Wiki and Tutor tabs. Their worth isn't throughput.
