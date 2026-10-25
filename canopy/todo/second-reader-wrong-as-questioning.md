+++
title = "Decide whether to show the second reader's wrong verdicts as worth questioning"
kind = "decide"
state = "open"
area = "second-reader"
size = "S"
why = "a soft label keeps the 4-in-5 useful catches without implying the reader knows when a comment is wrong"
links = ["/Users/philbrockman/sweeps/viewer-redesign-2026-10-21/second-reader/RESULTS.md", "memory:project_canopy-v2.md"]
created = "2026-10-25"
updated = "2026-10-25"
+++

Backtest on 33 held-out threads: 21/33 exact verdicts; "wrong" precision 4/5 but recall 4/13 — the deciding facts were mostly outside the repo.
So "wrong" is right when it fires but misses most real cases. Relabelling it "worth questioning" in `review/Thread.tsx` (VERDICT map) is the proposal.
