+++
title = "Measure whether the shipping-desk bets moved forest span, push timing and approved-to-merge"
kind = "look"
state = "waiting"
area = "dashboard"
size = "S"
why = "tells me if opening whole forests, pushing before 15:00 and the launch sheet actually shortened time to merge"
waiting = "a few weeks of use after the 2026-10-21 redesign (re-run around mid-November)"
links = ["wiki/loops/viewer-redesign-rnd.md", "memory:project_viewer-redesign-2026-10.md"]
created = "2026-10-25"
updated = "2026-10-25"
+++

Baselines: forest first-open → last-merge median 164 h; PRs opened ≥15:00 PT take 18.8 h to merge vs 3.2 h; approval → merge p90 78 h.
Re-run `scripts/viewer-usage-report --repo ~/coding/loops` and compare. Raw reports/scripts in `~/sweeps/viewer-redesign-2026-10-21/`.
