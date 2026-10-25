+++
title = "Find any branch, forest, concept or wiki page from the v2 menu"
kind = "build"
state = "open"
area = "keys"
size = "M"
why = "one keystroke reaches anything, which is what lets the rail shrink to Forests"
links = ["wiki/loops/canopy-v2-interaction.md", "wiki/loops/canopy-v2-plan.md"]
rank = 6
created = "2026-10-25"
updated = "2026-10-25"
+++

Phase 3 of the plan. v2's `space` menu (`v2/Menu.tsx`) filters commands only; v1's Cmd+K finds every branch across forests (`/forest-branches`).
Wanted: branches and forests from the `/state` store, plus Tutor concepts and wiki pages, all as palette results that dispatch through the runner.

## Next steps
Design: *Every action is a registry command* — a result is a command plus an argument (`find.branch`, `find.forest`, …), so opening one is timed, counted by id and shows in the `?` sheet like everything else; *data through /state* — branches and forests come from the store already; no new endpoint for them.
1. `commands/app.ts` — `find.branch` (arg: branch id → review page) and `find.forest` (arg: project id → Forests with it opened and selected); quiet, so they don't list in the menu themselves.
2. `Menu.tsx` — below the matching commands, matching branches and forests from `list("branch")` / `list("project")` (name, description, forest), dispatching `find.*` with the id; same fuzzy match the commands use; archived last.
3. Slice 2 (separate item if it grows): wiki pages and tutor concepts — they aren't in `/state`; decide between a small `docs` domain and leaving them to `place.*`.
4. Test: the menu's matching/ordering as a pure function beside `Menu.tsx` (test first); budget `local` for find.forest, navigation is timed by the router.
Verify: npm test; Puppeteer — `space`, type part of a branch name, `↵` lands on its review page.
Done when: `space` + a few letters reaches any branch or forest, which unblocks retiring v1's Cmd+K.
