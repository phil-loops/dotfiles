+++
title = "Decide whether bless survives next to v2's viewed marks"
kind = "decide"
state = "done"
area = "v1-retire"
size = "S"
why = "/bless is v1's most-used write (172) and v2 keeps a separate viewed ledger; check what still reads the bless ledger before retiring it"
created = "2026-10-27"
updated = "2026-10-27"
+++

## Done
2026-10-27 — 2026-10-27 — retire bless with v1. Nothing outside v1 decides on it: push, gates, outbox, packet and /state never read stack-blessed.json; v2 doesn't call /model. Readers are all v1-side (FileRail, stack-forest node payload, stack-model → /model, picker cache key, retired nvim stack-blessed.lua). Last /bless 2026-10-21; viewed.json has replaced it since 10-25. When v1 goes: delete stack-bless, stack-blessed-status, stack-model, test-stack-bless.sh, the blessed parts of stack-forest, nvim stack-blessed.lua; leave the ledger file on disk.
