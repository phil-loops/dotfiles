+++
title = "Review a teammate's PR stack as a forest"
kind = "build"
state = "open"
area = "review"
size = "L"
why = "reading a stacked teammate series gets the same map, walk and preview as my own forests"
links = ["wiki/loops/foreign-forests.md", "memory:project_viewer-foreign-forests.md", "d1f6bf5"]
created = "2026-10-25"
updated = "2026-10-25"
+++

Slice 1 (serving chip, d1f6bf5) is built in v1. Not built: (2) `srv/foreign.py` deriving the DAG from gh PR base→head chains, read-only; (3) a switcher to walk it with "⇄ preview here" on /preview-swap; (4) readiness (migrations etc.) folded into the swap.
Decisions already taken (2026-09-07): enter via the switcher's PR tab, never the forests list; GitHub depth = comment counts + deep links; migrations at swap auto-apply only if on origin/main.
Build on v2's review page (teammates' `review/pr-N` already open there) rather than v1.
