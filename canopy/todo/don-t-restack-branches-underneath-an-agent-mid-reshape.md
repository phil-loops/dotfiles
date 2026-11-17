+++
title = "Don't restack branches underneath an agent mid-reshape"
kind = "fix"
state = "open"
area = "forests"
size = "M"
why = "canopy restacked a forest while an agent was reshaping it; carry lists computed against the old main then picked up main's commit"
created = "2026-11-17"
updated = "2026-11-17"
+++

Seen 2026-11-17: canopy restacked branches while an agent session was mid-reshape of the same forest. The agent's carry lists were computed against the old main and then picked up main's commit.

## Next steps
1. Decide the claim: a forest being reshaped by a session (reforest / patch work) holds a lease the viewer's restack and sync respect (like the `own` lanes, but per forest).
2. Restack/sync refuse with "<session> is reshaping this forest" while the lease is live, and say how to take it over.
3. Regression: a restack request against a leased forest is refused and moves no ref.
