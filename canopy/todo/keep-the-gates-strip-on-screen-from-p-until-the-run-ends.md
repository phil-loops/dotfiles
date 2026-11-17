+++
title = "Keep the gates strip on screen from p until the run ends"
kind = "fix"
state = "open"
area = "gates"
size = "S"
why = "after p the whole strip (push key, stage, gates rows) vanishes until the run finishes, so a live run shows nothing"
created = "2026-11-17"
updated = "2026-11-17"
+++

Seen 2026-11-17 on cite-the-openai-checks-activity: press `p`, the ship strip on the title row goes blank and stays blank for the whole run. `, g` brings it back (it re-reads progress with a gate param and the read sees the live run).

## Cause (read from the code, not yet driven live)
1. `p` → `branch.gates.run` writes the optimistic op `gates: running` (`BranchCommands.swift:78`) before the server has spawned the detached run.
2. That flips the `.task` key in `ShipStripView`, so `ShipState.readProgress` (`ShipState.swift:203`) reads once — and the server still answers the PREVIOUS, finished run (`running: false`, with a `result` event). It only re-polls every 2 s while the answer says `running`, so it never asks again until `b.gates` changes at the end.
3. Every face then turns itself off: `pushRoute` is now `branch.gates.next`, so `acts` is false and the push key is gone; `GatesRun.waiting` returns nil because the stale progress holds a `result` event (`Gates.swift:195`); `stripShown` is false (not running, no red).

## Next steps
1. `ShipState.readProgress` — keep polling every 2 s while the branch itself says `gates == .running`, not only while the last answer did.
2. `GatesRun.waiting` — with `inFlight`, a progress that already holds a `result` is the previous run: say "gates starting", don't return nil.
3. Remove the `withKnownIssue` wrappers in `GatesStripRegressionTests.swift`; both tests must then pass plainly.
Done when: from `p` to the last gate the strip always says something, and the two regression tests pass without `withKnownIssue`.
