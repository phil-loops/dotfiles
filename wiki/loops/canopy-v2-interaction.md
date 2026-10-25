---
title: Commands, keys and three surfaces
section: Canopy v2
order: 53
project: canopy-v2
lede: Every action is a named command with one key, reachable from the palette. Three surfaces, each one job. Reading and writing are separate modes.
---

**One command model.** Every action is a command with an id, a title, a key, a scope (global, forest, branch, line) and a run function. Buttons, keys, right-click menus and the palette all dispatch commands. The `?` sheet is generated from them, so it can't drift, and telemetry is keyed by command id, so renaming a label never splits the data.

**Keys follow Helix where they overlap:**

- `space` opens a command menu.
- `K` shows types; `gd` goes to definition.
- `j`/`k` move, `↵` opens, `esc` backs out.
- `m` shows the map, `e` edits the words, `o` opens in Helix.
- `f`/`w`/`X` set focus, workbench and archive; capitals toggle what's shown (`A` the archive, `F` only what's ready, `O` outdated conversations).

No key means different things on different pages — `bindings.test.ts` loads the registry and fails on any key that does, unless the two commands are listed there as the same move (`j` is next row and next line).

**Three surfaces:**

1. **Forests (home).** Focus, the workbench, the archive. A forest expands inline into its branch spine, with ship readiness on each branch (green, pushed, in review, approved and waiting) — the outbox becomes this page's "ready" filter, not a separate place.
2. **Branch.** One reading column: diff, types on demand, the words in a side panel on `e`. The spine and map are overlays, not columns.
3. **The palette.** Find anything — branch, forest, concept, wiki page — and run any command.

Tutor, Wiki and Machine stay, as palette destinations rather than rail tiles.

**Ergonomic rules:**

- A row's primary action is on `↵`, and nothing else shows until you hover or select.
- Nothing destructive happens without a second keypress.
- Every wait over 300 ms says what it's waiting on.
