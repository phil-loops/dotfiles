+++
title = "Check whether the per-endpoint caches still earn their keep after the in-memory git graph"
kind = "look"
state = "open"
area = "perf"
size = "S"
why = "fewer caches means fewer ways for the viewer to show something stale"
links = ["memory:project_viewer-forest-page-perf.md", "memory:project_canopy-leverage-plan.md"]
created = "2026-10-25"
updated = "2026-10-25"
+++

`srv/gitgraph.py` + `fastgit.py` (2026-10-13) made `_COMMITS_CACHE`, `_CDIFF_CACHE` (review.py), `_PREVIEW_CACHE` (push.py) and `_mcache`/`_pcache` "candidates for removal", but `_root_fresh_cache` and the memo still beat uncached 3–5×.
Bench each with the cache off; delete the ones that don't matter. Some serve only v1 endpoints — may be simplest after v1 retires.
