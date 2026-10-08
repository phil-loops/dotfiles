---
title: The oracle and the read set
section: Viewer
order: 14
project: viewer-derived-state
lede: The keystone is a read set over predicates, not keys. But no read set over refs and config can validate a stack-forest payload at all, because the payload carries git-status output — so payload composition has to be fixed first.
---

Invariants: [[viewer-derived-state-shape]]. Domains: [[viewer-derived-state-domains]].

**The oracle** — `repostate`, grown into the authority: all refs, the parsed config with both
namespaces resolved, the worktree list, and **derived indexes once per epoch** —
`parent → children`, `project → members`. The indexes are what make membership one cheap
function and let readers share one graph. One refresher polls while `ctx.watched()`, so cost
is O(1) spawns per interval, not O(readers).

**Volatile fields must leave the payload.** `stack-forest:648` runs `git status --porcelain`
in every worktree holding a forest branch and bakes the result into `nodes[b]["dirty"]`. That
is filesystem state with no entry in refs or config, so **no read set can ever validate the
payload that contains it** — and it is why `/node` was left with no memo at all. The fix is
not a cleverer fingerprint: dirt becomes a short-TTL **overlay painted at serve time**,
exactly the `_overlay_live` pattern `picker.py` already uses for the triage axes and gates
verdicts. One volatile field was poisoning the cacheability of twenty stable ones.

**Read sets over predicates.** `stack-forest:102` reads the *whole* config into
parents/children/seeds; `:218` reads *all* `refs/heads`. Recording point keys would record
everything — today's repo-wide stamp. An entry records the **predicate and a digest of its
match set**: the closure's ref tips, config lines naming a member, and a **frontier guard** —
a digest of the children lists at the closure's edge — so a branch created mid-build with
`stack-parent` pointing at a member invalidates although its key did not exist to record.
That phantom is the primary workload, not an edge case.

**The trap:** the epoch is a label and a short-circuit, never a validity criterion. The moment
it decides validity it is `model_sig()` again.

**Membership, once:** registry ∪ per-branch tag, descended by parent edge, skipping a child
tagged elsewhere, ancestors never filtered. The union is the point — reading the registry
alone is what blinded the palette.
