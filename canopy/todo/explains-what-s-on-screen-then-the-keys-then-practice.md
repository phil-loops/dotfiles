+++
title = "? explains what's on screen, then the keys, then practice"
kind = "build"
state = "doing"
owner = "8778bd36"
area = "keys"
size = "M"
why = "2026-11-02: Phil kept asking 'what am I looking at' (on #N vs to push, draft, only here, all changes, gate glyphs); ? only answers 'what can I press'"
created = "2026-11-02"
updated = "2026-11-02"
+++

## Shape (redesigned 2026-11-02 with Phil: the sheet is the way)

`?` is one press, one sheet, never empty:
1. **Where you are** (generated, always): the mode under the sheet, the cursor's position, and that mode's way out (`KeyEngine.modeKeys`). Every non-normal mode also prints its way out on the statusline, so a text-entry mode (`/`, where `?` types) can't trap you.
2. **On screen** (authored, optional): the Terms / `.explains` notes on screen, as word — meaning. The section is absent when there are none. Typing filters notes and keys together.
3. **The keys**, as before.

Why not callouts beside each element (dfb3628's layer): it depended on every view authoring notes, so it read as broken on most screens and cost a second `?` to reach the keys. Removed.

## Next steps
- Notes on the forests home and the forest page (row glyphs and words, the lifecycle bands) — reach for a Term first.
- Cursor on a note's row narrows the keys to what acts on that thing (old step 2).
- Keys in the sheet link to their keytutor step (old step 3).

## The principle (2687288)

A word canopy shows and what it means are one value: a `Term` (word + meaning), drawn with `TermText` so the note registers with the word. Kinds of state are enums conforming to Term (`HistoryGroup`, `Reach`, `RowName`); an exhaustive switch makes a new case carry a meaning or not compile. Free-text `.explains(id, text)` stays for one-off status lines drawn in exactly one branch of code (the ship strip).
