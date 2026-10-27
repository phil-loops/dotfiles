+++
title = "Move Work, Wiki, Tutor and Machine onto v2, then retire v1"
kind = "build"
state = "open"
area = "v1-retire"
size = "L"
why = "one app, one key registry covering every page, and ~15k lines of v1 gone"
blocked_by = ["pick-diff-bases-and-edit-the-branch-description-on-the-v2-br"]
links = ["wiki/loops/canopy-v2-plan.md", "memory:project_canopy-v2.md"]
created = "2026-10-25"
updated = "2026-10-27"
+++

v2's places (`g w|i|t|m`) still jump into v1 pages (`v2/commands/app.ts`). Until they're v2 surfaces, `canopy/keys.toml` and the `?` sheet can't cover them and v1 can't be deleted.
Plan rule: each page moves only once it beats v1 on the dashboard; the server only gains endpoints until v1 is gone.
