---
title: Viewed, per change
section: Canopy v2
order: 61
project: canopy-v2
lede: A change stays reviewed until its own text changes — not when another hunk in the file moves, and not when a rebase shifts it or edits the lines around it. Decided 2026-10-25.
---

**Today.** "Viewed" is per file: `stack-bless` writes `$GIT_DIR/stack-blessed.json` as `{branch: {path: blob}}` (a leftover of the nvim `stack-blessed.lua`), and v2's `v` posts `/bless`. The key is the file's blob, so any change anywhere in the file un-views the whole file: a fix in another hunk, or a rebase that brings in main's edits to the same file. The ledger holds 391 entries across 116 branches.

**The unit is a change block, not a hunk.** A block is a run of consecutive `-`/`+` lines. Git's hunks are blocks grouped by context width (3 lines by default): two changes 5 lines apart are one hunk, and if the code between them changes they become two. Keying on blocks makes the split/merge question disappear: a hunk is viewed when every block in it is.

**A block's identity is its own text.**
- Key = hash of the file path and the block's `-` lines then `+` lines, exact text.
- No line numbers, so it survives rebases and shifts.
- No context lines, so main editing the neighbouring lines doesn't un-view it.
- Two identical blocks in one file are told apart by their order of appearance.
- A rename re-opens review, because the path is part of the key (as on GitHub).

**The store is per branch.** `$GIT_DIR/stack-viewed.json`, `{subject: {key: at}}`, where a subject is a branch name.
- Reshaping a forest (splitting a branch, moving a commit to a child) drops the moved changes' reviews. That's accepted.
- *Room for a whole-feature review:* the store is keyed by subject, not by "branch", so a forest's integration ref (`refs/stack/<project>-integration`, diffed against main) can be a second subject, viewed independently of its branches. Whether v2 gets that view is undecided, and nothing here retires it.

**On the page.**
- **A file rolls up from its blocks:** the tree shows "3/5" when partly viewed, and a file counts as viewed when all its blocks are.
- **`v` on a line views that line's hunk;** `v` on the file header views the whole file, as now.
- **`u` undoes it.**
- **A block that changed shows as new,** so a re-review lands on exactly the edited hunk.
- **Data:** viewed keys arrive as a `viewed` domain of `/state`, and the page derives each block's state. Writes are optimistic commands: `POST /viewed {repo, keys, on}`, with an inverse for undo.

**Decided** (Phil, 2026-10-25):
1. **Context stays out of the key:** a change stays reviewed when only its neighbouring lines change.
2. **Per branch:** reviews belong to the branch they were made on; reshaping the forest drops them.
3. **The integration-ref blessing stays:** a whole-feature review beside per-branch review is undecided, and the store leaves room for it.
4. **Start fresh:** no migration from `stack-blessed.json`, so everything shows unreviewed once. The old ledger is left as it is, for v1.

**Build.**
1. Pure `blocksOf(file)` in `review/diff.ts`. Tests: the same change keyed identically at `-U1` and `-U10` (merge/split), after a line shift (rebase), with edited context; a key change when a `+`/`-` line changes.
2. `srv/viewed.py`: the store, the domain, `POST /viewed`.
3. The page: hunk and file roll-ups, `v` per hunk, the tree count.
4. v2 stops reading and writing `/bless`; v1 keeps it.
