+++
title = "Make ? searchable: typing filters the sheet in place"
kind = "build"
state = "done"
area = "keys"
size = "S"
why = "Phil 2026-11-02: ? should be more discoverable/searchable. The searchable list exists (space ?, Menu.swift) but is a second key you have to know; ? itself can't be filtered"
created = "2026-11-02"
updated = "2026-11-02"
+++

- One surface: while ? is open, a typed letter starts a filter over the grouped sheet (a16c80a's sections stay; empty sections drop out). The sheet's own scroll keys move to ctrl-n/ctrl-p or arrows while filtering.
- Match like the menu does, plus synonyms: Menu.swift:67 is a plain substring over "title id". Add a small synonym table ("diff" → code/files, "back" → esc commands, "commit message" → reword).
- space ? can then become an alias for ? with the filter already focused.

## Done
2026-11-02 — typing while ? is up filters the grouped sheet in place (empty sections drop out, the anywhere cap lifts); j/k/? keep scrolling and closing until something's typed, then backspace edits, C-n/C-p scroll, ↵ runs the first match. Matches every word against title, id, verb, label and key, plus KeySheet.synonyms (diff→code/files, back→esc, message→reword…). Engine: KeyEngine.layerTyping, a layer's raw keys before its keymap; KeyName names backspace. space ? left as the command menu — not aliased.
