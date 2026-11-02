+++
title = "Group and rank the ? key sheet by what each key acts on"
kind = "build"
state = "done"
area = "keys"
size = "M"
why = "Phil 2026-11-02: in the commits view ? lists 33 lines under one 'the Review page' heading; esc and 3 (the keys back to the code) sat between k and gg, and 10 lines were motions he already knows"
created = "2026-11-02"
updated = "2026-11-02"
+++

## Target (commits view)

```
? · commits · "drop the unused prisma import"

THIS COMMIT
  ret     read its code
  i       reword it
  esc     back to the whole branch's code

SHOW
  1 2 3   conversation · commits · code
  ,b p/m/o  diff against parent · main · origin
  ,o      outdated threads

THIS BRANCH
  s sync · e words · o open in Helix · g h finish · g p preview

OTHER BRANCHES
  J K next/prev · g k g j parent/child · g K g J root/tip

MOVE   j k · gg G · w b · h l · space f filter · space m map
```

## How to factor

1. **The scope already groups the inner targets; only `.review` is a catch-all.** Inner scopes (history, line, thread, words) keep their own heading from `KeySheet.labelOf`, worded as "this commit" / "this line". Add `group: KeyGroup?` to `Command` (`CanopyCore/Keys/Registry.swift`) with `enum KeyGroup { show, branch, others, move }`, set only on `.review` and `.global` commands.
2. **Movement is derived, not tagged.** A command whose verb has `VerbTier.nav` and is a motion (next/previous/left/right/top/bottom/word) defaults to `.move`. No per-command tagging for those.
3. **Pairs render as one entry.** `Command.pair` already links next/prev (`history.next` ↔ `history.prev`); the sheet joins a pair into one line ("j k next/prev") instead of two.
4. **`sheetNow` (`CanopyCore/Keys/Keymap.swift`) stays pure and owns the order.** `SheetCmd` gains `group` and `uses`. Output sections in a fixed order: innermost scope, show, branch, others, anywhere, then the one collapsed MOVE line. Within a section, sort by `uses` desc, then registration order. Unit-test it with a fixture, no UI.
5. **Usage counts come from the runner, not a server round trip.** `Runner.dispatch` already builds a `cmd` event with the id and `via`; also bump a per-id count with zoxide-style aging (the multipliers already chosen in NAV.md) persisted locally, and pass it in as `uses`.
6. **`KeySheet.swift` only renders sections.** The current label-grouping loop in `KeySheet.model` goes away.
7. **Guard like `everyVerbIsTaught`.** A registry test fails when a `.review` or `.global` command has no group and isn't a derived motion, so new commands can't fall back into one undifferentiated list. A second test pins the commits-view sheet: it starts with `history.open`, `history.write`, `history.exit` and has at most ~14 lines.

## Done
2026-11-02 — ? now reads innermost scope (this commit / this line) first, then the page's own keys under show · this branch · other branches, then the 8 most used anywhere keys, then every motion on one move line. Pairs (j k, J K) and the numbered tabs (1 2 3) are one line each; order within a section is frecency from the usage log plus each run. KeyGroup.of derives most groups from the verb; ReviewArea.placeInSheet places the rest; everyReviewKeyHasASheetGroup guards it, SheetSectionTests pins the commits-view order.
