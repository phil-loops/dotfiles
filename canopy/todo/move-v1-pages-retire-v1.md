+++
title = "Move Work, Wiki, Tutor and Machine onto v2, then retire v1"
kind = "build"
state = "done"
area = "v1-retire"
size = "L"
why = "one app, one key registry covering every page, and ~15k lines of v1 gone"
links = ["wiki/loops/canopy-v2-plan.md", "memory:project_canopy-v2.md"]
created = "2026-10-25"
updated = "2026-10-27"
+++

v2's places (`g w|i|t|m`) still jump into v1 pages (`v2/commands/app.ts`). Until they're v2 surfaces, `canopy/keys.toml` and the `?` sheet can't cover them and v1 can't be deleted.
Plan rule: each page moves only once it beats v1 on the dashboard; the server only gains endpoints until v1 is gone.

## Done
2026-10-27 — 3f7b9cb 80dda37 0477652 fd75d07 1adc0f2 — v1 deleted: every src/ file v2 doesn't import (~15.7k lines), the v1 entry, visual harness and static bake; v1 URLs (and /) 302 to their v2 page or /v2, no ?v1 or off-switch. Server lost ~45 v1-only routes and the srv code only they used (processes.py gone); /chat stays for the mail-map. Bless removed end to end (scripts, stack-forest ledger reads, /bless, nvim sb/sB/gd/]u, zsh verbs); ledger files left in .git. Work tab, NextQueue and review-requests went with v1 unported. The branch-page extras (diff bases, description editor, force-origin, freeze) are not built — see pick-diff-bases-and-edit-the-branch-description-on-the-v2-br.
