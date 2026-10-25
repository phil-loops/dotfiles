---
title: Viewed, per change
section: Canopy v2
order: 61
project: canopy-v2
lede: A change stays reviewed until its own text changes — not when another hunk in the file moves, and not when a rebase shifts it or edits the lines around it. Spec, not built.
---

**Today.** "Viewed" is per file: `stack-bless` writes `$GIT_DIR/stack-blessed.json` as `{branch: {path: blob}}` (a leftover of the nvim `stack-blessed.lua`), and v2's `v` posts `/bless`. The key is the file's blob, so any change anywhere in the file un-views the whole file: a fix in another hunk, or a rebase that brings in main's edits to the same file. The ledger holds 391 entries across 116 branches.

**The unit is a change block, not a hunk.** A block is a run of consecutive `-`/`+` lines. Git's hunks are blocks grouped by context width (3 lines by default): two changes 5 lines apart are one hunk, and if the code between them changes they become two. Keying on blocks makes the split/merge question disappear: a hunk is viewed when every block in it is.

**A block's identity is its own text.**
- Key = hash of the file path and the block's `-` lines then `+` lines, exact text.
- No line numbers, so it survives rebases and shifts.
- No context lines, so main editing the neighbouring lines doesn't un-view it.
- Two identical blocks in one file are told apart by their order of appearance.
- A rename re-opens review, because the path is part of the key (as on GitHub).

**The store is per repo, not per branch.** `$GIT_DIR/stack-viewed.json`, `{key: {at, branch}}`.
- *Why:* reshaping a forest (splitting a branch, moving a commit to a child) moves changes between branches, and the same change is the same review.
- *The cost:* identical changes on two branches count as viewed on both. That's correct: it's the same diff.

**On the page.**
- **A file rolls up from its blocks:** the tree shows "3/5" when partly viewed, and a file counts as viewed when all its blocks are.
- **`v` on a line views that line's hunk;** `v` on the file header views the whole file, as now.
- **`u` undoes it.**
- **A block that changed shows as new,** so a re-review lands on exactly the edited hunk.
- **Data:** viewed keys arrive as a `viewed` domain of `/state`, and the page derives each block's state. Writes are optimistic commands: `POST /viewed {repo, keys, on}`, with an inverse for undo.

**Decisions**, each with a recommendation:
1. **Context stays out of the key:** a hunk stays viewed when the lines around it change. Recommended. Context-sensitive review is what re-reading the hunk is for, and keying on context would bring back the rebase problem.
2. **Per repo, not per branch.** Recommended: it survives forest reshaping.
3. **Retire the integration-ref blessing** (`refs/stack/<project>-integration`). Recommended: it belongs to v1's ghost node, and v2 has no such view.
4. **Migrate the old ledger once, then retire it.** For each `(branch, path, blob)` whose file at the branch tip still matches the blob, mark that file's current blocks viewed. `stack-bless` stays read-only until v1 retires.

**Build, once decided.**
1. Pure `blocksOf(file)` in `review/diff.ts`. Tests: the same change keyed identically at `-U1` and `-U10` (merge/split), after a line shift (rebase), with edited context; a key change when a `+`/`-` line changes.
2. `srv/viewed.py`: the store, the domain, `POST /viewed`, and the one-time migration.
3. The page: hunk and file roll-ups, `v` per hunk, the tree count.
4. Retire `/bless` from v2.
