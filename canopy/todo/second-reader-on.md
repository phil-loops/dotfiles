+++
title = "Turn on the second reader"
kind = "decide"
state = "open"
area = "second-reader"
size = "S"
why = "every review thread arrives with a checked verdict, the same issue elsewhere, and a draft reply"
links = ["memory:project_canopy-v2.md", "wiki/loops/canopy-v2-review.md", "/Users/philbrockman/sweeps/viewer-redesign-2026-10-21/second-reader/RESULTS.md"]
rank = 5
created = "2026-10-25"
updated = "2026-10-25"
+++

`scripts/stack-second-reader` + `srv/second_reader.py` are built and run when a PR gets a new review (a544380), but stay off until `git config stack.second-reader true`.
Cost on Opus: ~$0.31 and ~22 s median per thread. It never posts; notes land in `<git-common>/stack-review-notes/<pr>/<thread>.json` and its draft reply is only inserted on `i`.
