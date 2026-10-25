+++
title = "Show proof branches as never-merge members of their forest"
kind = "build"
state = "open"
area = "forests"
size = "S"
why = "an e2e/smoke branch riding a forest reads as part of it instead of an odd unshipped node"
links = ["memory:project_forest-proof-branch-role.md", "62c0f70"]
created = "2026-10-25"
updated = "2026-10-25"
+++

`stack-proof` sets `branch.<b>.stack-role=proof`; stack-doctor, stack-integrate and the pre-push guard honour it. The viewer doesn't: no badge, still offered push/PR affordances.
Wanted: a quiet off-spine mark, no ship word or push in v2, and (later) a run button driven by a `stack-proof-cmd` key — "forest green" = gates + proof ran.
