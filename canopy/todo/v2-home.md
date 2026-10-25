+++
title = "Make v2 the home page"
kind = "decide"
state = "open"
area = "v1-retire"
size = "S"
why = "/ opens the faster Forests page (paint p50 15 ms vs 150 ms) instead of v1"
links = ["memory:project_canopy-v2.md", "wiki/loops/canopy-v2-plan.md"]
created = "2026-10-25"
updated = "2026-10-25"
+++

Switch: `git -C ~/coding/loops config stack.viewer-v2-home true` makes `/` serve v2. Off until Phil decides.
The plan's rule: switch once v2 beats v1 on the dashboard (`g D`, `/v2/dashboard`) — Phase 1 numbers already do.
