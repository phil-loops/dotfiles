+++
title = "Check whether I still hand-reload pages I don't trust to refresh"
kind = "look"
state = "open"
area = "dashboard"
size = "S"
why = "a manual reload is the clearest sign the live updates aren't trusted"
links = ["memory:project_viewer-usage-telemetry.md"]
created = "2026-10-25"
updated = "2026-10-25"
+++

v1 telemetry (2026-07-12) showed cmd+r / cmd+shift+r ~10 a day — never addressed. v2 pushes patches over `/v2/events`, which should end it.
Check whether v2 telemetry records reloads (PerformanceNavigationTiming type "reload"); if not, add it, then compare v1 vs v2 pages.
