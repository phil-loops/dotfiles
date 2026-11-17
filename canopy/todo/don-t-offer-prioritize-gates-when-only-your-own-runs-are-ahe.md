+++
title = "Don't offer 'prioritize gates' when only your own runs are ahead"
kind = "fix"
state = "open"
area = "gates"
size = "S"
why = "on let-disable-take-a-suspicious-activity, p read 'prioritize gates' while waiting on another run Phil had clicked; the press can't move it, says 'these gates go next' anyway, and the bar just flickers"
incarnation = "i_9a5a3c2e184c459e810b377e8d7a849f"
created = "2026-11-17"
updated = "2026-11-17"
+++

From Phil, 2026-11-17 15:38 ("hitting p seems to make that bar flicker?"): `let-disable-take-a-suspicious-activity` showed "○ waiting on record-the-banned-word-activity-first · 29s" and `p` = "prioritize gates". The run ahead was also Phil's click (`interactive` tier), so `POST /gates {next:true}` (`push.py` `gates`) promotes nothing and answers `{ok, next, was: "interactive"}`. The client still says "these gates go next — p pushes once they're green" (`branch.gates.next`, `BranchCommands.swift`), and the strip redraws: the flicker is the only visible effect.

## Next steps
1. `pushRoute` → `branch.gates.next` only when the run is queued behind work Phil didn't click: the queue's setup event already carries `ahead` by tier (`{"interactive": n, "ship": n, "background": n}`); with nothing ahead but `interactive`, `p` has no route here, and the line says "behind your <branch>".
2. `branch.gates.next`'s `said` reads the answer: `was == "interactive"` → "already next among yours — waiting on <branch>".
3. If the flicker remains once `p` has nothing to do, record the strip (the press → the answer → the next progress read) and find which view swaps.
4. Test on `pushRoute`: queued behind only interactive work → no `gates.next` route.
