+++
title = "Choose the type service's memory limit and whether every hover gets a fresh checker"
kind = "decide"
state = "open"
area = "machine"
size = "S"
why = "types on hover cost ~3 GB of a 16 GB box; the trade between exact answers, speed and memory is mine to set"
links = ["wiki/loops/canopy-v2-types.md", "/Users/philbrockman/sweeps/viewer-redesign-2026-10-21/types-service/types-service-research.md", "ed0a31c", "3a473b1"]
created = "2026-10-25"
updated = "2026-10-25"
+++

`srv/lsp.py`: GOMEMLIMIT 3000MiB holds tsgo flat at ~2.9 GB with both diff halves (off: 4.0–4.5 GB; 2000MiB GC-thrashes at 700–800% CPU).
Fresh checker per hover (`STACK_LSP_FRESH_CHECKER`, on) makes hover text order-independent but costs 0.2–0.5 s per uncached hover vs 0.02–0.05 s warm; without it, 2000MiB held 2.2 GB.
Options: keep as is; drop fresh checkers and lower the limit; or idle tsgo out sooner (`STACK_LSP_IDLE` 600 s) when memory pressure is high.
