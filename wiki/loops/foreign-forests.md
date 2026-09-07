---
title: Foreign forests
section: Viewer
order: 10
project: foreign-forest
lede: The viewer can author your forests but cannot see anyone else's. Reviewing a teammate's stack live is the same map with the pencil taken away.
---

## The incident that names the gap

2026-09-07, reviewing maksim's `footers-6…14` stack (footer editor feature, ~9 stacked PRs):

1. **Wrong-branch review comments.** Phil commented on PR 10407 (`footers-11-settings-subpage`) while the preview on `:3011` was serving `footers-10-editor` — the parent. Two of three comments described the parent's known intermediate state, which the PR under review fixes. Nothing anywhere bound *the PR being read* to *the branch being served*.
2. **Walk-the-stack round trips.** Every "now look at footers-12" was a manual sequence — fetch, checkout, kill server, relaunch, poll — with port roulette (3011→3012→3011) when the old listener hadn't freed.
3. **Drift discovered by 500.** The shared dev DB was missing the footer migrations; the borrowed Prisma client and package dists were stale. Each surfaced as a runtime error mid-review, though the machinery to *predict* all three already exists.

The viewer's world is `stack-branch.*` git config. Maksim's stack has none, so the viewer cannot render it, and every capability that would have helped — preview swap, provenance, drift detection — has no node to hang off.

## What already exists (inventory, not redesign)

- **`POST /preview-swap`** (`stack-review-server.py:515`, `srv/preview.py#swap`) — flip the *same port* to another branch's worktree; before/after in one tab. This is the walk primitive, already built.
- **`/preview-wait` interstitial** (`srv/preview-wait.html`) — warming page, log tail, healthy→redirect; `preview.py start()` is idempotent (`reused: true`).
- **Provenance stamp** — `loops-provenance` patches `next.config.js` so dev servers send `X-Dev-Worktree: <branch>@<sha> <path>`; `loops-preview` auto-stamps; `whoport` reads it back and ⚠-warns on header/cwd disagreement.
- **`whoport --stack`** — migration-head diffs per checkout against the shared DB (`_prisma_migrations`, ClickHouse), no patches needed.
- **The Machine page** (`MachinePage.tsx`) — shared-infra provenance/drift already renders in the viewer.
- **The map** — `forestGraph.ts` + `ForestMap.tsx` render a DAG from parent edges; nothing in the geometry requires the edges to come from git config.

## The missing noun

A **foreign forest**: a stack the viewer renders but does not own. Derived, not configured:

- **Source of truth: GitHub.** `gh api` the open PRs, chain `base`→`head` refs into parent edges (maksim's PR bases point at each other; branch naming like `footers-N` corroborates order). Author + shared base cluster them into one forest.
- **Read-only by construction.** No gates, no prep, no push, no restack — the entire authoring grammar is absent, not disabled. The one verb a foreign node carries is *preview*.
- **No local branches until preview time.** Ingestion is pure API; `fetch` + worktree materialize lazily when a node is first previewed (the swap plumbing already shells out this way).

## Slices, in landing order

### 1 · Identity binding (first — it caused the actual damage)

Wherever a PR/branch diff is being read with a preview alive, show what the preview port is *actually serving*: read `X-Dev-Worktree` the way `whoport` does, render `:3011 → footers-10-editor@f322fb` as a quiet chip. Match = silence. Mismatch with the node being viewed = the one loud ⚠ this surface is allowed (badge precedence: *will-ambush*).

Second half: a **dev-only in-app ribbon** — extend the `loops-provenance` patch so the stamped app renders its own `branch@sha` in-page (corner ribbon, dev builds only, working-tree patch, never committed to loops). Then the browser tab itself can't lie, even when the viewer isn't open. This slice needs no foreign-forest machinery at all and pays for itself against your *own* forests too.

### 2 · Ingestion + the read-only page

A `srv/foreign.py` that turns `gh` PR JSON into the same graph shape `forestGraph.ts` consumes; foreign forests appear as rows in `ForestsList` (marked foreign — italic name or `⇄` glyph, no new rail button, no new tab). Clicking in gives the same map — *map is the app* — with nodes carrying PR number, title, CI state, and the `parent...head` diff via the existing file rail. All GitHub state renders read-only; comments deep-link out to GitHub (the viewer never mutates GitHub, same rule as the gh-page chip).

### 3 · The walk rail

On a foreign node, ONE pipeline verb: **⇄ preview here** → `/preview-swap` onto the node's branch (materializing the worktree first if needed) via the `/preview-wait` interstitial. Prev/next follow stack order — the spine grammar already encodes navigation. Per-node review state (seen / commented, from GitHub data) is a quiet dot, never a button. Four-slot check: verb = preview-swap; checkpoint = none (nothing to voice); shared-world door = the GitHub deep-link; status = spine.

### 4 · Readiness at swap

Fold the predictions *inside* the preview verb, not as peer buttons: at swap time run the `whoport --stack` migration diff, the unbuilt-dist check (now in `loops-preview` itself, 529df51), and a Prisma-client staleness check. Green = swap proceeds silently. Red = the interstitial names what it's fixing (`applying 2 migrations · building realtime-client`) or parks with the reason. The condition may also render as passive metadata on the node ("needs migration") — metadata, not a button.

## The honest cost

This adds a **second audience** to the viewer: today it serves the author (Phil's forests, gates, push); this serves the reviewer (anyone's stack, read + run). That is a real scope expansion, on top of an open list that already includes the forest-detail redesign, semantic zoom, and lifecycle debt. Mitigations: slice 1 is not actually foreign-forest work (it hardens existing preview provenance and would have prevented this morning's damage alone); slices 2–4 reuse the map, the swap, and the interstitial rather than growing new surfaces; and the read-only constraint keeps the authoring grammar from leaking sideways.

## Open questions for Phil

1. **Where does a foreign forest live in the UI?** Proposed: same `ForestsList`, visibly foreign. Alternative: behind a Cmd+K jump only, no list presence at all (quieter, but undiscoverable).
2. **How much GitHub state on the node?** Diff + CI + comment *count* with deep-links (proposed), or render full comment threads read-only in the viewer (heavier, duplicates GitHub, but keeps review in one place)?
3. **Does slice-4 auto-apply migrations to the shared dev DB, or park and ask?** Auto is the smoother walk; the DB is shared with the main checkout, and a teammate branch could carry a migration main doesn't have yet (this morning's were already on origin/main, so safe — that's not always true).
