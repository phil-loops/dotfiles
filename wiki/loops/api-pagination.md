---
title: Pagination foundation
section: API foundation spikes
order: 10
project: api-pagination
ask: lib/rest-api/pagination.ts
lede: nextPage is rebuilt from two params; the first filterable list endpoint ships broken links on day one.
---

Every public list route returns a [`nextPage` URL](src:lib/rest-api/pagination.ts#buildPaginationMeta) materialized from exactly `cursor` and `perPage`. Any other query param — a filter, a sort — is dropped from the link, so a client following it would paginate the *unfiltered* collection.

**Nobody is bitten today.** All ten list routes validate with [`listQueryValidator`](src:lib/rest-api/pagination.ts#listQueryValidator), which knows only those two params; unknown input is stripped before it reaches the DB, so `nextPage` is currently consistent with behavior. The bug is fully latent — and the metrics API is exactly the filterable list endpoint that detonates it. Nothing in types or tests would flag it.

`nextPage` can't be dropped: it is a **required** property of the published `Pagination` schema (openapi.json), though every doc description steers users to `nextCursor` instead. So: fix, don't delete.

**The fix** — `buildPage`/`buildPaginationMeta` take the *validated* zod output (`query.data`) instead of a bare `perPage`, and rebuild `nextPage` with `URL` + `URLSearchParams` (which also fixes the missing cursor encoding). Validated-only input means the link reflects params the route actually applied, never echoes arbitrary junk. Ten call sites change mechanically.

**Forest** (chain, one concern each):

1. `api-pagination/next-page-query` — rebuild nextPage from the validated query object; util + 10 call sites + tests.
2. `api-pagination/consolidate-lists` — replace the byte-equivalent hand-rolled hasMore/slice/nextCursor blocks in `campaigns/index.ts` and `transactional-emails/index.ts` with `buildPage`; zero customer delta.
3. `api-pagination/per-page-min` — relax the arbitrary min-10 clamp to 1, plus its duplicate in the workflow list validator and ~10 doc strings; only turns 400s into 200s.

**Out of scope:** migrating those two routes to `defineRoute` (auth/validation ordering flips 400↔401), and legacy `/v1/transactional` (deprecated; its post-filter cursor has a documented dangling-cursor quirk we're leaving alone).

**Merge priority (Phil, 2026-08-17):** branch 1 is the prerequisite — it's the shared util the metrics list endpoints build on, and its old-endpoint touches are byte-neutral signature mechanics. Branches 2 and 3 are pure-conformance polish, explicitly **parkable** — push them whenever, or never; nothing downstream depends on them.
