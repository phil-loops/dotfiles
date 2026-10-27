---
title: The sync contract — /state and /v2/events
section: Canopy v2
order: 57
project: canopy-v2
lede: The v2 store hydrates once from a snapshot, then applies entity patches the server pushes per domain. One config write is one small patch, never a refetch.
---

Design: [[canopy-v2-architecture]]. Code: `srv/state.py`.

**`GET /state`** returns `{epoch, versions, entities}`. Entities are keyed by type, then id:

- `repo`; `project` (state focus/workbench/archive, rank, ticket, summary);
- `branch` (parent, description, own commits, tip, tree, pushed, gates for this tree, its merge-order position, its hold-for-morning stamp, and what ⟲ sync would fix from the refs alone: `behind` main, `drifted` off its parent, a footgun `upstream`, a `diverged` pushed copy — dirt and the prep route are read per branch on its page);
- `pr` (number, url, state, review, base, approvals, merge state — what an approved PR waits on), from the caches only, never gh;
- `landed`, the merge ledger's shipped steps.

Ids are `<repo>:<name>`. Archived projects are listed, but their branches and PRs only come with `?archived=1`.

**`GET /v2/events`** (SSE), connected with the versions the snapshot returned:

- `hello {epoch, versions}` on connect;
- `patch {domain, version, upserts, deletes}` whenever a domain changes;
- `resync` when the client can't be caught up: refetch `/state`, then reconnect.

**Two domains, each with its own version:**

- `git` covers repos, projects and branches. It rebuilds only when the stat-gated repo fingerprint or a gate job moves.
- `remote` covers PRs and landed steps. It's rebuilt from memory every tick.

The server diffs each rebuild against the last one and keeps the last 128 patches. Every version is the previous one plus one, so the client treats a gap as a resync. A POST wakes the refresher, so its patch follows the response within milliseconds.

**Measured on the live repo (2026-10-22, read-only harness):** warm `/state` 2 ms (p95 3); after a config write 25 ms; after a ref move 100 ms. The snapshot is 103 KB (265 KB with the archive).
