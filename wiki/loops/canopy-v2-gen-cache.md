---
title: A cache for generated tRPC types
section: Canopy v2
order: 59
project: canopy-v2
lede: seed-gen stores every tRPC types emit under the exact inputs the compiler read, so any tree whose inputs were built before restores them instead of compiling.
---

**Keyed by what the compiler read.** A stored emit carries its compiler graph and every path module resolution probed. A tree hits only when those files hash the same and every probe answers the same. The key also covers package.jsons read or missing, node_modules links, configs, the compiler's files and seed-gen's. Each part has a counterexample in `test-seed-gen-cache`.

**Restore is a clone.** `clonefile` copies the entry, which is checked against its sha256 manifest. Only changed files are swapped in, so the type service hears real changes only. The tsbuildinfo is re-spelled for the tree, so a no-op `tsc` re-emits nothing.

**Only full builds are stored.** TS7's incremental emit under `noCheck` skipped declarations inferred from a changed file, so seed-gen now always emits in full. An entry is stored only if no input changed during the build.

**Gates audit, never restore.** A gate rebuilds and compares with the stored entry. A mismatch evicts the entry and writes a `poison/` report.

**Measured.** Across 282 live-branch commits, 43% reuse another commit's emit. In 20 fresh trees, restores equalled independent builds, and gate typechecks matched on all three tried. A revisited sibling takes 5 s against 9–13 s; a fresh review tree 7 s against 11 s.

`seed-gen --cache-stats` · `--cache-gc` · `SEED_GEN_CACHE=0` turns it off.
