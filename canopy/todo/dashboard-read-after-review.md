+++
title = "Read the v2 dashboard after the review page and target what's most over budget"
kind = "look"
state = "open"
area = "dashboard"
size = "S"
why = "the next round of work goes where it's slowest times most used, not by taste"
links = ["wiki/loops/canopy-v2-measure.md", "wiki/loops/canopy-v2-plan.md"]
created = "2026-10-25"
updated = "2026-10-25"
+++

Plan rule: each phase ends with a dashboard read (`g D`, `/v2/dashboard`, `/telemetry/summary`) and a short note on what it changed. Phase 2 (review page) landed 2026-10-23 without one recorded.
Look at commands over budget (feedback 16 ms / settled 300 ms / paint 100 ms) weighted by use, and the never-used list.
