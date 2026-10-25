+++
title = "Backtest the second reader on Sonnet against the 33 saved threads"
kind = "look"
state = "open"
area = "second-reader"
size = "S"
why = "if Sonnet matches Opus, the reader gets several times cheaper and faster per thread"
links = ["/Users/philbrockman/sweeps/viewer-redesign-2026-10-21/second-reader/", "memory:project_canopy-v2.md"]
rank = 12
created = "2026-10-25"
updated = "2026-10-25"
+++

Saved threads + the Opus results live in `~/sweeps/viewer-redesign-2026-10-21/second-reader/` (RESULTS.md has the scoring). Opus baseline: 21/33 exact, wrong precision 4/5, recall 4/13, ~$0.31 / 22 s per thread.
Re-run the same 33 with Sonnet and compare verdicts, cost and latency.
