+++
title = "Steal a seed-gen lock whose holder is dead, not only one older than 10 minutes"
kind = "fix"
state = "open"
area = "gates"
size = "S"
why = "a seed-gen run died at 15:18 holding its tree's locks; the gates run then sat 'stuck preparing the checkout' for 10 minutes"
created = "2026-11-17"
updated = "2026-11-17"
+++

Seen 2026-11-17 on record-the-banned-word-activity-first: the gates run sat at setup step "checkout" for 6m+ ("stuck preparing the checkout"). Both of the checkout's locks — `<gitdir>/seed-gen.lock` and `.gen/.rebuilding` — were made at 15:18 and no live process held them. The two waiting `seed-gen --sync`s (one from the gates' `stack-open --path`, one from the server's) slept in `wait_lock`, which only steals a lock older than 600 s. The dead holder left no heavy-turn journal row, so it was killed rather than exiting through its EXIT trap.

## Cause (traced from the server log, the branch reflog and the gate queue)
1. 15:17:49 — Phil's `p` started a gates run; its checkout step (`stack-open --path` → `seed-gen --sync`) took the tree lock `<gitdir>/seed-gen.lock` and `.gen/.rebuilding` at 15:18.
2. 15:18:32 — the disable-evidence session committed a fixup and rebased the branch (reflog `38d4d7a`).
3. `gate_queue.py` saw the tree change under a running run and called `stop(child)`: SIGTERM to the group, then **SIGKILL 5 s later** if it hasn't exited. bash defers its EXIT trap until the foreground child (the types build) returns, so the build died first and the trap never ran. Even when it does run, `finish` drops only the tree lock, never `.gen/.rebuilding` (`seed-gen:71`).
4. 15:18:46 — the run that `p` then queued for the new tree, and the server's own heal, both waited in `wait_lock` on locks no one held. The 600 s age rule was the only way out; a peer session `rmdir`'d the lock at ~15:25.

## Next steps
1. `seed-gen` `wait_lock`: write the holder's pid into the lock dir on `mkdir`; a waiter steals at once when that pid is dead (`kill -0` fails), keeping the 600 s age rule for locks with no pid.
2. Regression test in seed-gen's test script: make a lock dir holding a dead pid; `wait_lock` returns within one poll, not after 600 s.
3. `finish` (the EXIT trap) also drops `.gen/.rebuilding` when this run took it, and seed-gen traps TERM so a stop ends the build and runs `finish` inside the 5 s window.
4. The gates' "stuck" note can name the cause: "waiting on a seed-gen lock held by <pid> (dead)".
