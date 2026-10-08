---
title: The oracle and the read set
section: Viewer
order: 14
project: viewer-derived-state
lede: Five moving parts replace nine caches and four invalidation stories. The keystone is optimistic concurrency: an entry records what it read, and validity is that nothing it read has moved.
---

Invariants this serves: [[viewer-derived-state-shape]].

**The oracle** — `repostate`, grown into the authority. One per repo, owning all refs, the
parsed config with both namespaces resolved, the worktree list, and a monotonic **epoch**
bumped when any input changes. One background refresher polls while `ctx.watched()`, so the
server costs O(1) spawns per interval rather than O(concurrent readers); readers never poll.
This absorbs `ctx.model_sig()`, `_MAX_AGE`, and the ~15 `worktree list --porcelain` callers
at 2.19s each.

**Read-set validity** — builders read through a recording view. An entry stores its access set
and each accessed value; validity is `all(oracle.now(k) == recorded[k])`. A transaction's read
set, applied to a cache. It retires three hacks at once: the `sig = ""` mid-build escape
hatch, the hand-maintained `_MODEL_CFG` allow-list, and the `_builder_sig` mtime fold-in. A
mid-build mutation is caught *precisely and only when it touched something the build read* —
including the membership query, which is what the 2026-07-21 contraction freeze actually
turned on.

**Builders in-process** — `stack-merge-rank` is already importable; `stack-forest` follows,
reading through the oracle. ~25 spawns become none. The largest latency win, and the one that
makes capacity nearly irrelevant, because a miss stops costing 30 seconds.

**Deltas on the wire** — the epoch bump carries what moved: refs, config prefixes, worktrees.
`/events` pushes that and the client maps delta → keys, so `forest-branches` refetches only
when `stack-project.*` or `branch.*.stack-project` moved and `/projects` only when a root tip
did.

**Admission control** — a global bound on concurrent children, single-flight everywhere, and
ambient work deferred while the gates queue is busy. `/previews` reached a 29.3s average
purely by having three copies of a docker scan in flight at once.
