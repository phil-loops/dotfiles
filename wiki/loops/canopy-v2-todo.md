---
title: The tracker, and /next
section: Canopy v2
order: 60
project: canopy-v2
lede: One list of what's left to build on the viewer — files in the dotfiles, a page in canopy, and a skill that ranks it, checks the design, and writes the next steps.
---

**One item, one file.** `~/.dotfiles/canopy/todo/<id>.md`: TOML frontmatter between `+++` lines (title, kind, state, area, size, why, waiting, blocked_by, links, rank), then notes in markdown. One file per item so concurrent sessions never write the same file; git is the history. Kinds: *build*, *fix*, *decide* (only Phil can make the call), *look* (a question to answer). States: open → doing → done, or waiting (on something named), or dropped.

**Only the viewer's work.** Loops product work lives in forests and Linear; this list doesn't copy it.

**Written through one door.** `scripts/canopy-todo` (add, ls, show, set, done, drop, rank, steps, check) and the page both go through `scripts/srv/todo.py`, which refuses an item that's missing what it needs (a waiting item has to say on what). A session that puts viewer work off files it here, instead of a "remaining" line in memory.

**The page.** `/v2/todo` (`g o`): needs you → doing → the ranked queue → waiting, as a `todo` domain of `/state` that moves when a file is saved. `↵` opens an item's notes, `I` starts it, `D` marks it done, `X` drops it (the same move as archiving a forest), `C-k`/`C-j` reorder within a section without disturbing the global ranking. `u` undoes any of them.

**`/next`.**
1. Closes out items that already landed, with evidence.
2. Ranks the queue by value over cost: Phil's one-line decisions, bugs he hits daily (telemetry), what unblocks the most, what's rotting.
3. Checks each top pick against the viewer's invariants: one source of truth, everything a registry command, data through `/state`, outward actions only through Phil, tests that load the real thing, measured, quiet.
4. Writes the next steps into each item. If the obvious build breaks an invariant, the first step is the design fix.
5. Stops and reports; Phil says go.
