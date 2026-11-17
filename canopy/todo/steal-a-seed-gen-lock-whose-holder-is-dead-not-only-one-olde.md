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

## Next steps
1. `seed-gen` `wait_lock`: write the holder's pid into the lock dir on `mkdir`; a waiter steals at once when that pid is dead (`kill -0` fails), keeping the 600 s age rule for locks with no pid.
2. Regression test in seed-gen's test script: make a lock dir holding a dead pid; `wait_lock` returns within one poll, not after 600 s.
3. The gates' "stuck" note can name the cause: "waiting on a seed-gen lock held by <pid> (dead)".
