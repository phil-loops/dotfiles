+++
title = "Choose between one server per repo and one server for every repo"
kind = "decide"
state = "open"
area = "server"
size = "S"
why = "removes the port-reclaim path where the two models still collide"
links = ["memory:project_viewer-lifecycle-debt.md"]
created = "2026-10-25"
updated = "2026-10-25"
+++

The server binds a per-repo stable port and reclaims it from another repo (`stack-review-serve`), yet also aggregates loops + monotoad via `stack.viewer-repos` in one process.
Supervision (launchd `com.philbrockman.canopy-server` + owner file) made this mostly dormant, but the contradiction noted 2026-07-22 was never decided.
