+++
title = "Check whether TS7's incremental noCheck bug also leaves task trpc:types stale, and note it upstream"
kind = "look"
state = "open"
area = "gen"
size = "S"
why = "the repo's own tRPC type build may be silently stale the same way seed-gen was"
links = ["wiki/loops/canopy-v2-gen-cache.md", "memory:project_canopy-v2.md"]
created = "2026-10-25"
updated = "2026-10-25"
+++

seed-gen found TS7's incremental emit under `noCheck` skipped declarations inferred from a changed file (left `lib/app-env/index.d.ts` stale), so seed-gen now always emits in full.
`task trpc:types` in loops may run the same incremental path. Reproduce there; if it does, file a minimal repro with microsoft/typescript-go.
