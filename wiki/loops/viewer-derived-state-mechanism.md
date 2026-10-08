---
title: The oracle and the read set
section: Viewer
order: 14
project: viewer-derived-state
lede: Four parts replace nine caches. The keystone is a read set over predicates, not keys — because a forest build reads two range queries, and a point-key read set would be no better than the stamp it replaces.
---

Invariants: [[viewer-derived-state-shape]]. Staging: [[viewer-derived-state-path]].

**The oracle** — `repostate`, grown into the authority: all refs, the parsed config with both
namespaces resolved, the worktree list, and **derived indexes computed once per epoch** —
`parent → children`, `project → members`. The indexes are the part that was missing; they make
membership a single cheap function and let every reader share one graph instead of rebuilding
it. One background refresher polls while `ctx.watched()`, so cost is O(1) spawns per interval,
not O(readers). Absorbs `ctx.model_sig()`, `_MAX_AGE`, and the ~15 `worktree list` callers.

**Read sets over predicates.** `stack-forest:102` reads the *whole* config into
parents/children/seeds, and `:218` reads *all* `refs/heads`. So recording point keys would
record everything — exactly today's repo-wide stamp. An entry must instead record the
**predicate and a digest of its match set**: the ref tips of the forest's closure, the config
lines naming any member, and — the phantom guard — a digest of the children lists on the
closure's frontier, so a branch created with `stack-parent` pointing at a member invalidates
even though its key did not exist at build time. That phantom is the *primary* workload: an
agent adding branches to a live forest every few minutes.

Validity is then re-evaluating those predicates against the in-memory indexes: microseconds,
versus the 34ms spawn it replaces. This retires the `sig = ""` escape hatch, the
`_MODEL_CFG` allow-list, and the `_builder_sig` mtime fold-in.

**The trap:** the epoch is a *label and a short-circuit* — "has anything moved at all", and
the "as of" a payload carries. The moment it becomes a validity criterion it is
`model_sig()` again, and the whole design has decayed back to what exists.

**Membership, once:** registry ∪ per-branch tag, descended by parent edge, skipping a child
whose own tag names another project, ancestors never filtered. The union is the point — a
tagged-but-unregistered branch is real work, and reading the registry alone is what blinded
the palette.
