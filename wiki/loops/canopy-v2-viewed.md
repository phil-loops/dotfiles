---
title: Viewed, per change
section: Canopy v2
order: 61
project: canopy-v2
lede: A change stays reviewed until its own text changes — not when another hunk in the file moves, and not when a rebase shifts it or edits the lines around it. Built 2026-10-25.
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

**Revised** (Phil, 2026-11-05, "fix it all" on six gaps):
1. **Duplicates take their neighbours.** The key is the path and the block's `-`/`+` text with whitespace dropped. When the same text appears twice in a file, each copy's key adds the unchanged line before and after it, falling back to order only when those match as well. Numbering by order alone let a new copy added above a read change take over its number and its mark. Decision 1 still holds for every block that isn't a duplicate.
2. **Whitespace is out of the key,** so a reformat (oxfmt, re-wrapped lines) keeps a block read. A change made only to whitespace inside a string literal goes unnoticed; that's accepted.
3. **A mark is one of three states:** unread, viewed or flagged. `, !` flags a change to come back to and moves on, `, m` reads it, and `, M` takes either mark off. `] u` / `[ u` stop on unread and flagged changes alike. A flagged change shows an ember bar and the file header counts ⚑n; a file with a flag in it isn't viewed.
4. **Marks are kept per block, as they're shown.** `, m` on a changed line marks that block; on an unchanged line or a gap it marks the hunk's blocks; on the header, the file. A hunk's unchanged lines dim once every block in it is read.
5. **The store follows the branch, not its name.** A subject is `branch.<b>.stack-review-id` in git config, minted on the first mark. `git branch -m` carries it, deleting the branch deletes it, and each write prunes marks whose id has no branch. Store version 2: `{version, subjects: {id: {viewed, flagged}}}`, migrated from version 1 on the first write.
6. **Reads are across the repo's branches (reverses decision 2):** a change read on one branch reads as read wherever the same block shows, so in a child carrying it or in the cumulative view. `, M` clears a key on every branch. One function (`ReviewPageState.serverMarks`) holds this, so going back to per-branch reads is a one-line change.
7. **Old marks still count:** each block keeps its pre-2026-11-05 key as `legacy`, and a mark stored under it still reads as viewed.
8. **A flag is a private bookmark with one list** (Phil, 2026-11-05: "keeping them somewhere where i can look at them"). A flag records where it was made: the file, the first changed line and that line's text (`POST /viewed` `where`, stored beside the flag). `space !` lists every flag in the repo, the branch you're on first and then the newest, and picking one opens its branch with the cursor on the change, found by block key or else by the nearest line. Flags don't become comments or questions to Claude.

**Build.**
1. Pure `blocksOf(file)` in `review/diff.ts`. Tests: the same change keyed identically at `-U1` and `-U10` (merge/split), after a line shift (rebase), with edited context; a key change when a `+`/`-` line changes.
2. `srv/viewed.py`: the store, the domain, `POST /viewed`.
3. The page: hunk and file roll-ups, `v` per hunk, the tree count.
4. v2 stops reading and writing `/bless`; v1 keeps it.
