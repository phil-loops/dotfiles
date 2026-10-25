+++
title = "Find why the first Forests paint takes seconds"
kind = "look"
state = "open"
area = "perf"
size = "S"
why = "v2 Forests paint p95 is 2.6 s against 100 ms — the first impression of the page that's meant to be faster than v1"
rank = 13
created = "2026-10-25"
updated = "2026-10-25"
+++

Telemetry, 30 days, n=2: `forests` paint p95 2583 ms. Likely a cold `/state` (refresh() on a just-bounced server builds every
domain) rather than rendering. Split the paint into fetch vs render before fixing anything.
