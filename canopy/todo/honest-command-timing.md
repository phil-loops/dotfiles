+++
title = "Stop timing commands that change nothing against whatever updates next"
kind = "fix"
state = "open"
area = "dashboard"
size = "S"
why = "the dashboard says clicking a row takes 895 ms; the real number is unknown, so it points work at the wrong place"
links = ["scripts/viewer-solid/src/v2/telemetry.ts"]
rank = 2
created = "2026-10-25"
updated = "2026-10-25"
+++

Telemetry, 30 days: `cursor.set` p95 895 ms (n=5) against a 16.7 ms feedback budget, `cursor.down/up` 33–36 ms.
`nextPaint(t0)` in `telemetry.ts` waits for the first DOM mutation anywhere, up to 1 s. A command that changes
nothing (clicking the already-selected row, `j` on the last row) stops the clock on an unrelated later
mutation — a `/state` patch, a warm-up fetch landing — so its time is noise up to the 1 s cap.

## Next steps
Design: *Measured* — a time that can belong to another event is a second, wrong source of truth. Solid applies a local command's DOM change synchronously inside `dispatch`, so "did it change anything" is knowable before the frame: if the observer holds no records when the command returns, it's a no-op.
1. `telemetry.ts` — `nextPaint` returns `{ ms: Promise<number|null>, changed(): boolean }`; `changed()` is `fired || obs.takeRecords().length > 0` (re-observing after takeRecords so the frame still resolves).
2. `runner.ts` — after `cmd.local(...)` (and after a write's optimistic `addOps`), if `!changed()` emit `outcome: "noop"` with no `feedbackMs`; no-ops keep their count but leave the latency stats.
3. `srv/telemetry.py` summary — exclude `outcome == "noop"` from feedback p50/p95 and `over`; report a noop rate per command (a high one is a UX signal: a key pressed where it does nothing).
4. Test: a summary test with a noop row (the Python side), and a Puppeteer check — click the selected row twice, the second event is `noop`.
Verify: npm test + typecheck; after a day of use, `cursor.set` p95 on the dashboard drops from ~900 ms to a frame or two.
Done when: no command's p95 is set by a press that changed nothing.
