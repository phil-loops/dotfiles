---
title: Derived state in the viewer
section: Viewer
order: 11
project: viewer-derived-state
lede: Nine symptoms, four decisions. Every forest view is a pure function of the repo, but the server rebuilds it by spawning shell scripts and guesses when to cache with a clock.
---

Measured baseline: [[viewer-derived-state-measurements]]. Invariants and target shape:
[[viewer-derived-state-shape]]. How to get there safely: [[viewer-derived-state-path]].

## The four decisions

1. **Reads spawn processes.** A model build is ~25 serial `git` spawns at a 34ms floor,
   because `stack-forest` and `stack-merge-rank` are *subprocesses* that re-read refs and
   config for themselves. The server's `repostate` snapshot already holds both; the process
   boundary is what forces the duplication.
2. **Invalidation is a clock or a coarse stamp, never a dependency.** `ctx.model_sig()` is
   whole-file `.git/config` mtime plus all 1,564 ref tips, so a gate verdict for an unrelated
   branch voids every forest. `repostate._MAX_AGE` is a 2s window with no single-flight, so N
   concurrent readers each re-read. `_LIST_TTL`, `_DB_TTL`, `_PR_STATE_TTL` and the 60s
   `_PREVIEW_CACHE` ceiling are four more clocks.
3. **Capacity is a magic number sized for a smaller repo.** `_MCACHE_MAX = 8` against ~157
   forests. No cache anywhere expresses its size in terms of what it caches.
4. **Change notification says "something moved", not what moved.** The pulse knows which
   fingerprint changed and tells the client `update`; the client invalidates 11 query keys,
   and `procs` invalidates 9 more. One commit lands and ~20 endpoints refetch.

## And one that is not a caching bug

**"Which branches are in project P" has three implementations that disagree under churn.**
`/forest-branches` reads the registry only; `/model`, `/projects` and `stack-forest` accept
registry ∪ per-branch tag ∪ descent by parent edge. Same class as the `stack-branch.*` /
`branch.*.stack-*` split that `repostate.branch_key` centralised — and it is why the palette
could miss a project the API already served.
