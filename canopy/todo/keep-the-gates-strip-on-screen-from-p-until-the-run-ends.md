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

**Second sighting, 2026-11-17 16:52 (add-disable-event-reason-column):** Phil pressed `p` (gates started; the label became "prioritize gates p"), pressed it again — no feedback either time. The run finished green in ~56 s (server: `gates: green` for tip b10a5e3) but the detail page never flipped to "push". Meanwhile the forest LIST row showed live progress ("gates ▪▪▪▪▮▫ 4/6 lint 12s"): it reads through `GateProgressRead` (7342c506, today 16:14), which polls every 2 s while watched, keyed by tree; the detail strip still reads through `ShipState.readProgress`, which stops after a not-running answer. The data existed; the detail page wasn't subscribed to it.

## The principled fix
One gate-progress reader per branch, shared: the detail strip renders the same `GateProgressRead` entity the list row does (keyed by tree, polling while the branch's gates are in flight), and `ShipState.readProgress` is retired. The door's label derives from that one source, so it flips to "push" the moment the verdict lands. Every `p` press is acknowledged on the status line with the run's live state ("gates running · lint 12s · 4/6 — p pushes when green"), including a press that only re-prioritizes.

## Next steps
1. Point `ShipStripView` at the branch's `GateProgressRead` (as `ForestGateProgressView` does) and retire `ShipState.readProgress`; polling then lasts while the branch's gates are in flight.
2. `GatesRun.waiting` — with `inFlight`, a progress that already holds a `result` is the previous run: say "gates starting", don't return nil.
3. Remove the `withKnownIssue` wrappers in `GatesStripRegressionTests.swift`; both tests must then pass plainly.
Done when: from `p` to the last gate the strip always says something, and the two regression tests pass without `withKnownIssue`.
