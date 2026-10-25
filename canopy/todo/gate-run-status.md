+++
title = "Show whether a branch's gate run is queued, running or stuck where push waits"
kind = "build"
state = "open"
area = "push"
size = "M"
why = "I can tell a wedged gate run from one waiting its turn without asking Claude"
links = ["memory:project_push-door-friction.md", "memory:reference_gates-queue-and-tmp-cleaner.md"]
created = "2026-10-25"
updated = "2026-10-25"
+++

`srv/gate_queue.py` already knows queued vs running per run, and `/gates-progress` has per-gate position, but the door/v2 rows show only green or not (`v2/ship.ts`).
Phil (2026-10-21) wants clearer per-check status and a way to see a run is actually moving.
Another session owns the push-door redesign (memory project_push-door-friction) — hand this to them or coordinate first.
