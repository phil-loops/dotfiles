+++
title = "Keep viewer-sandbox away from the machine's real preview servers"
kind = "fix"
state = "open"
area = "machine"
size = "S"
why = "the sandbox's /previews lists real previews (e.g. :3010) and its kill/restart/reap/run-main act on real processes, so 'test it in the sandbox' isn't safe for the Machine page"
created = "2026-10-27"
updated = "2026-10-27"
+++
