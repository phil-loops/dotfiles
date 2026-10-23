---
title: Types on both halves of a diff
section: Canopy v2
order: 58
project: canopy-v2
lede: One long-lived tsgo reads viewer-owned trees that move between commits instead of starting cold per branch, and every answer is byte-identical to a fresh tsgo on a fresh tree.
---

**Trees that move, not start over.** The viewer owns a pool of four detached worktrees (~240 MB each). A commit goes to the tree already holding its lockfile and `packages/`. `git checkout` then rewrites only the differing files, so hopping forests doesn't re-derive node_modules or the prisma client.

**tsgo hears every change.** The client declares dynamic watch registration, so tsgo runs no watcher of its own. Each changed path goes over as a `didChangeWatchedFiles` event before the next request. A changed dependency view, or more than 1,000 changes, restarts tsgo instead.

**Generated types only when their inputs move.** seed-gen runs only when the diff touches the tRPC emit's graph, configs, manifests or `packages/`.

**Both halves.** A removed line asks at the diff's base. That is a second tree, served by the same tsgo, and its project unloads after three idle minutes.

**Canonical answers.** Three tsgo behaviours leaked history into answers; each is neutralised:

- hover text follows checker history, so each hover gets a fresh checker;
- loose files share one inferred program, so they are asked alone;
- background type acquisition changes loose files' types, so it is off.

**Memory.** Expect ~1.5 GB for one project and ~2.9 GB for both halves, held flat by `GOMEMLIMIT=3000MiB`. tsgo starts at the first K unless `STACK_LSP_PREWARM=server`.

**Proof.** `test-lsp-differential` compares answers after incremental moves with a cold tsgo on a fresh tree, byte for byte.
