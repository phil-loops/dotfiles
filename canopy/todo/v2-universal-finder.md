+++
title = "Find any branch, forest, concept or wiki page from the v2 menu"
kind = "build"
state = "done"
area = "keys"
size = "M"
why = "one keystroke reaches anything, which is what lets the rail shrink to Forests"
links = ["wiki/loops/canopy-v2-interaction.md", "wiki/loops/canopy-v2-plan.md"]
created = "2026-10-25"
updated = "2026-10-27"
+++

Phase 3 of the plan. v2's `space` menu (`v2/Menu.tsx`) filters commands only; v1's Cmd+K finds every branch across forests (`/forest-branches`).
Wanted: branches and forests from the `/state` store, plus Tutor concepts and wiki pages, all as palette results that dispatch through the runner.

## Next steps
Slice 1 landed: `space` + letters fuzzy-finds any branch (archived forests' too) or forest, and a PR number finds its branch (`v2/find.ts`, `find.branch`/`find.forest` in `commands/app.ts`).
1. Slice 2: wiki pages and tutor concepts — they aren't in `/state`; decide between a small `docs` domain and leaving them to `place.*`.
2. Then retire v1's Cmd+K.

## Done
2026-10-27 — c51d328 — slice 2: the space menu also finds wiki pages and tutor concepts; v1's Cmd+K retires with v1
