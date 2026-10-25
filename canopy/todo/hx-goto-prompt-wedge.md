+++
title = "Stop a slow open leaving Helix stuck in its :goto prompt"
kind = "fix"
state = "done"
area = "review"
size = "S"
why = "shift+O from GitHub left ':goto 73' half-typed and Helix swallowed the next keys"
created = "2026-10-25"
updated = "2026-10-25"
+++

## Done
2026-10-25 — bb27cd5 — hx_cmd closes its own prompt on failure; stack-open-test reproduces and passes
