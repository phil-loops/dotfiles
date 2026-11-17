+++
title = "Mark a sync step that couldn't run as failed, not done"
kind = "fix"
state = "open"
area = "review"
size = "S"
why = "the steps strip showed '✓ tests' beside 'tests couldn't run', and '✓ gates' while the gates line said stuck"
created = "2026-11-17"
updated = "2026-11-17"
+++

Seen 2026-11-17 on record-the-banned-word-activity-first (Phil's screenshot): the sync motion's steps strip read `✓ working tree ✓ commit shape ✓ gates ✓ tests`, with the note "tests couldn't run" under it, while the title row said "stuck preparing the checkout · 6m 8s".

## Next steps
1. `StepsStrip` (`ShipStripView.swift`) and the motion's step states: a step whose note says it couldn't run is a failed (or skipped) step — ✗/– with its note, never ✓.
2. The gates step's ✓ means "gates handed off", not "gates green": name it for what it did ("gates started") or keep it live (◌) while the run it started is running.
3. Test on the step model: a step that reports "couldn't run" is not done; a gates step whose run is live is not done.
