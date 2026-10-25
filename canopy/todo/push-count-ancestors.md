+++
title = "Stop the push door counting unpushed ancestor commits as this branch's"
kind = "fix"
state = "open"
area = "push"
size = "S"
why = "the push count should say what this branch sends, not its parents' unpushed work"
links = ["memory:project_push-door-friction.md"]
created = "2026-10-25"
updated = "2026-10-25"
+++

A stacked branch whose parent has unpushed commits shows those commits in its push count.
The outgoing set should be the branch's own (`origin/<b>..<b>`, else `<b> --not --remotes=origin` minus the parent's range). Check `_origin_verdict` in `srv/push.py` and v2's push count in `v2/ship.ts`.
Note: another session owns the push-door redesign (memory project_push-door-friction) — coordinate before touching the door UI.
