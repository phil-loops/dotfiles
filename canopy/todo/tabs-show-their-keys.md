+++
title = "Tabs show their keys; retire the , h commit picker"
kind = "build"
state = "done"
area = "nav"
size = "S"
why = "tabs are places reached by name (space c/h/g); the label should say the key at the moment you want the tab, and choosing a commit has one home (j k in the commits tab)"
created = "2026-11-05"
updated = "2026-11-05"
+++

## Design (from the purge-import-files session; Phil's direction 2026-11-05)

1. Each review tab's label prints its key: `conversation ␣c · commits ␣h · files ␣g` (glyph from the registry, not hard-coded — read the bound key for .conversation / .history / .changedFiles).
2. Retire `, h` (`review.scope` picker, ReviewDiffCommands.swift ~449): choosing a commit is j/k in the commits tab. The ScopeChip's `, h` hint (ReviewPage.swift ~142) goes; `↵`/click on the chip opens the commits tab (`space h`). Add `(", h", "space h", .history)` to `Verbs.moved` so the old key says where it went.
3. `space 1–9` stays as "the Nth choice" (pickers, prompts), no longer documented as the tab keys; update the `nth` meaning text + NAV.md decision entry: "a tab is reached by its name, not its slot".
4. Tests: retire/adjust the `, h` picker tests (ReviewTests ~700); a test that every tab label carries a key that is bound.

Full `swift test` before landing; compare the complete failing-name list against the known Ship flakies.

## Done
2026-11-05 — Landed: space 1–9 no longer opens a review tab (review.tab.* keep no key; clicks and links still reach them); nth reads as the Nth choice in a picker or prompt, taught on the address picker; NAV.md decision 'a tab is reached by its name, not its slot'; test everyTabIsReachedByItsNameNotItsSlot. Not built: (2) retiring , h — superseded by f88267cf, which re-made , h as the branch-line cursor and made the commits tab words-only, so 'choose a commit with j k in the commits tab' no longer holds; (1) tab labels with keys — the review page has had no tab strip since e1cfa224 (tabs gave way to an outline), so there is no label to print a key on; filed as show-the-review-tabs-with-their-keys for Phil's call.
