# Migration: per-branch `stack-branch.<b>.project` tag → replace the `stack-project.<name>.branch` registry

**Why:** the `stack-project.<name>.branch` multivar is a *separate, hand-maintained list of
branch names*. It rots — deleting/renaming a branch leaves a dangling entry (happened
2026-06-16: `delete-team/enqueue` had to be manually `--unset` after deletion). Moving membership
onto the branch (`stack-branch.<b>.project = <name>`) means it **can no longer dangle a central
list**. That is the whole win.

**Keep / drop:**
- DROP (membership): `stack-project.<name>.branch`  → becomes `stack-branch.<b>.project`
- KEEP (project metadata, keyed by name, doesn't rot): `stack-project.<name>.memory`, `stack-project.<name>.archived`

## Status

- ✅ **Phase 1a — backfill done (live, loops repo):** 37 `stack-branch.<b>.project` tags written from
  the current registry. Verified: every branch was in exactly one project (no multi-project loss).
  Tags are **inert** until the dual-read patch lands (nothing reads them yet) — safe to sit ahead.
  Reverse: `git config --unset stack-branch.<b>.project` per branch.
- ✅ **Phase 1b — `patches/project-tag-dual-read.patch` (forest lane, stack-forest):** stack-forest
  ALSO reads `stack-branch.*.project` into `seeds` (+ order-preserving dedup so a branch in both the
  registry and a tag isn't double-counted). **Tested:** identical `--projects` output on the real
  repo (backward compat), and a tags-only scratch repo resolves projects correctly. `git apply --check` clean.
  → cross-lane: this is the **forest** lane change `topo_order` delegates to. Forest holder, please review/land.

## Remaining touch points (from the stack-restack owner)

stack-restack both reads AND writes the registry. With dual-read in place the **reads keep working**
(registry still present); the **writes** are where the simplification lands:

| stack-restack site | today | after migration |
|---|---|---|
| `topo_order` fallback read | reads registry / delegates to stack-forest | resolves via tags (stack-forest already dual-reads) |
| start-mode project validation | reads registry | accept a project that any tag references |
| ORPHANS scan | reads registry | scan `stack-branch.*.project == <proj>` |
| ORPHAN-cleanup write | rewrites `stack-project.X.branch` multivar | just `--unset stack-branch.<orphan>.project` (no list to rewrite) |
| TO_DROP-removal write | rewrites the multivar | `--unset` the dropped branch's tag |
| re-seed-roots write | rewrites the multivar | **no-op** — tags already live on the surviving branches |

**This deletes the multivar-rewrite dance entirely** — which also retires the O(n²) "rewrite the list
inside the per-orphan loop" footprint (the `restack-footprint-guard` area). Coordinate exact lines with
the stack lane owner (9eea070c offered review).

### Other consumers to switch (then the registry read can be deleted everywhere)
- **stack-list** (stack): enumerate projects from distinct `stack-branch.*.project` values.
- **stack-rm** (stack): on branch delete, also `git config --unset stack-branch.<b>.project`.
  ⚠️ **Gotcha:** `git branch -D` does NOT remove `stack-branch.<b>.*` keys — `.project` needs explicit
  cleanup. But an orphan tag on a since-deleted branch is **invisible** (no branch → never resolved by
  stack-forest's `expand`) and sweepable; it cannot dangle a list. Net strictly better than today.
- **.zshrc `_loops` completion** (shell, ~line 203): ✅ **patch staged — `patches/project-tag-completion.patch`**
  (reads `stack-branch.*.project` as primary, registry as deduped fallback; `zsh -n` clean; map verified no-dupes
  against the live config). NOT landed — `.zshrc` is dirty with another session's WIP; `git apply --3way` it when quiet
  (applies clean today, no overlap). Still TODO: set the tag at branch creation / in `loops purpose`.
- **swiftbar/blessed.sh**: reads the registry — switch to tags.

## Phasing
1. **1a/1b (here):** backfill + stack-forest dual-read. Tags work everywhere stack-forest resolves;
   registry still authoritative for writers. No behavior change. ← *review + land this*
2. **2:** writers switch to tags — stack-restack write-sites become unset/no-op (deletes the rewrite
   dance), stack-rm unsets on delete, stack-list/.zshrc/swiftbar read tags.
3. **3:** drop the `stack-project.*.branch` registry reads + the entries themselves (keep `.memory`/`.archived`).
