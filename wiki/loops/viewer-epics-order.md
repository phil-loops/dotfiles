---
title: The epic page and cross-project order
section: Viewer
order: 21
project: viewer-epics
lede: Merge order across projects is derivable from edges that already exist, but content edges and after edges are different claims and must not be drawn the same way.
---

Schema and rollup: [[viewer-epics]]. The card: [[viewer-epics-card]].

## Cross-project order, from edges that exist

`srv/review.py` `_continuations` already finds branches whose `stack-parent` is a node another
project owns — a content dependency crossing a project boundary. `requires` and `after` can
name a foreign branch the same way. So the epic's project DAG is: for every member branch, if
`parent`/`requires`/`after` names a branch belonging to a different project in this epic, add
that edge between the two projects. Topologically sort, tie-broken by milestone order then
declared order.

**Content and deploy edges are different claims and must render differently.** `parent` and
`requires` mean "cannot build without"; `after` means "nothing local reds, but prod breaks if
these land out of order" (forests.md). Drawing them identically would erase the only
distinction that matters when Phil picks what to merge next.

And the epic page must **not** re-derive intra-project order — it consumes each project's own
`mergeOrder` verbatim, per the standing warning that re-sorting by `mergeRank` client-side
reintroduces drift.

## The page

`/epics` and `/epics/<id>`, a new `head === "epics"` branch in `parseLocation`; read-only GETs
`/epics` and `/epic?id=<id>`. Per milestone: title, goal, criteria with their met state, and
its projects with the rolled-up work counts. Then an explicit **outside the milestones**
section — `parity-replay` and `phishtank-later` live there, and without it an unassigned member
is simply invisible.

**It must ride the `/projects` cache.** The epic payload is one `stack-epic` config sweep plus
rows the picker already computed; a second independent fan-out would make it another 8–16s
endpoint ([[viewer-derived-state-measurements]]).

**The home card drops members today.** `ForestsList.tsx:86` skips a project that is shelved,
not committed-tier, focused, or recently merged, and needs ≥2 survivors — so a focused or
parked project silently leaves its epic. That filter is defensible for the *card*; the *page*
must show every member regardless.

## Staging

Read-only first: render from config written by hand or a `stack-epic` CLI in the **forest**
lane. Phase 1 needs no mutating endpoint at all, which keeps the whole `__probe__` risk class
out of it. Mutations — assign a project, check a criterion — come second, once the shape has
survived a week of real use.
