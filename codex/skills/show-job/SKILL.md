---
name: show-job
description: Report a long-running job's progress (an eval, a backfill, a bulk script expected to run longer than ~10 minutes) to Phil's Show app with `show-job`, so he can watch it without a tmux window and hears when it ends.
---

# show-job

Phil watches long jobs in Show's Runs workspace. Report a job that you expect to run for more than about 10 minutes through `~/.dotfiles/scripts/show-job`; the file format behind it is not yours to write.

```sh
show-job set <id> --title "Fresh holdout eval" \
  --row "e4b 412/2389 warm cache" --row "sonnet 0/2389" \
  --line "memory 63% used" --line "disk 41 GB free"
show-job done <id> --note "all three models finished"
show-job fail <id> --note "worker exited 137"
```

- `<id>`: letters, digits, `.`, `_`, `-`; stable for the whole run.
- `set` sends the **whole** current state each call, never a change: every row, every line. Call it about every 30 seconds from the job's loop or a watcher.
- A row is `label done/total note`: the first `N/M` splits the label from an optional note. Show draws its progress, rate and ETA.
- Once no `set` arrives for 10 minutes, Show marks the job "stalled?". Call `done` or `fail` when it ends, and `fail` from your error path too, so a dead job never looks merely slow.
- `done` and `fail` post one note to Phil's Inbox; don't send another.

**Privacy: rows, lines and notes carry counts, timings, model names and labels only.** Never put email text, subjects, addresses, contact data or any customer content in them, not even a sample.
