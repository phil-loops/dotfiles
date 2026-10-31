+++
title = "Backfill restrictions for every disabled domain, then turn on the nightly check"
kind = "build"
state = "open"
area = "migration"
project = "loops:domain-enforcement"
size = "M"
why = "computing disabled from rows needs a row for every current block"
blocked_by = ["enf-restrictions-on-every-disable", "enf-query-no-event-disables", "enf-query-reenabled-but-disabled"]
links = ["show/enforcement-design.json"]
created = "2026-10-31"
updated = "2026-10-31"
+++
