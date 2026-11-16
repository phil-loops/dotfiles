+++
title = "Re-gate only what a fix touched"
kind = "build"
state = "open"
area = "gates"
size = "M"
why = "a branch whose own diff changed re-pays the whole typecheck (60-140s) and whole-project lint (~40s) for a one-line fix"
created = "2026-11-15"
updated = "2026-11-15"
+++

Key each gate on what it reads, not the whole tree:

- **format / oxlint**: per-file, cache by blob SHA — re-run only changed files (knip stays whole-project).
- **typecheck**: whole-program, so not skippable — seed the gate worktree with the parent's `.tsbuildinfo` keyed on the parent's tree (beware the known stale-tsbuildinfo-after-donor-refresh trap) so a descendant pays only its delta.

Already covered: descendants whose own diff is unchanged (`gates-survive-rebase`, and reviews since 6c9080ce) and tests (`delta_tests` runs only the delta's). 2026-11-15's slow forest was mostly a verification mistake and gating between review rounds — both fixed in push-ready — so measure before building: this only pays on branches that change repeatedly.
