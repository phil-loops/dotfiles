+++
title = "Decide whether dead branches get archived on a schedule"
kind = "decide"
state = "open"
area = "machine"
size = "S"
why = "repo size is the recurring root of slow pages; keeping it small stops needing a sweep every month"
links = ["memory:project_viewer-forest-page-perf.md", "0dd85fe"]
rank = 19
created = "2026-10-25"
updated = "2026-10-25"
+++

`scripts/branch-archive` (0dd85fe) moves merged/squash-merged/stale-30d branches to `refs/archive/<date>/` with `--restore`; first run took 1592 → 727 heads. It only runs by hand — nothing schedules it (worktree-hygiene has a launchd agent; this doesn't).
Loops is at 576 heads / 221 worktrees today. Scheduling it moves refs without asking, hence Phil's call.
