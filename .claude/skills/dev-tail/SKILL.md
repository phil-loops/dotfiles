---
name: dev-tail
description: Tail and inspect the loops dev server log to diagnose stuck requests, slow queries, errors, and hung jobs. Use when the user reports the dev server seems hung, a request is spinning, the audience-count is stuck, a tRPC call doesn't return, or any "what's going on in dev right now" question.
---

# Dev Server Tail

Inspects the running loops dev server's recent output to surface the actual error / slow query / hung request causing a problem the user is observing in the browser.

## When to use

- "The audience count is stuck spinning"
- "tRPC call XYZ never returns"
- "Why is /audience hanging?"
- "What's the dev server doing right now?"
- Any time the user reports a UI symptom and the cause is server-side

## How to use

The user's dev server runs via `task dev:loops` (or similar) and writes stdout/stderr to a known log file. Convention: `/tmp/loops-dev.log`. If the user's running dev without piping to that file, ask them to restart with:

```
task dev:loops 2>&1 | tee /tmp/loops-dev.log
```

(Or whichever `task dev:*` command they're using.)

### Steps

1. **Check the log exists**: `ls -la /tmp/loops-dev.log`. If it doesn't, ask the user to enable it as above and stop.

2. **Tail the recent output**: `tail -n 300 /tmp/loops-dev.log` and look for:
   - Stack traces or `error` lines
   - Slow query warnings or queries that started but never finished
   - tRPC handler invocations without matching completions
   - Long gaps in timestamps (server hung)
   - `Job status not found`, `Canceling unwatched job`, `Failed`

3. **For job-runner issues**: also check what's in `JobStatus` table for the relevant teamId:
   ```
   PGPASSWORD=password psql -h localhost -U postgres -d postgres \
     -c 'SELECT id, operation, status, progress, result, "createdAt" FROM "JobStatus" WHERE "teamId"=$$<teamId>$$ ORDER BY "createdAt" DESC LIMIT 5;'
   ```
   `Processing` for a long time = job is hung; `Failed` means it errored (check log for stack).

4. **For ClickHouse-backed paths** (goal-state filters, email events): also probe CH directly to confirm the underlying query works without the job wrapper. Run the equivalent SQL via `clickhouse-client` or a small `tsx` script.

5. **Report back**: paste the relevant log lines and identify the most likely cause. Don't dump the whole log — surface the 5-20 lines that matter.

## Live tail (for ongoing observation)

If the user wants to watch as something runs:
```
tail -f /tmp/loops-dev.log
```
Use `run_in_background=true` and read the output stream.

## What this skill does NOT do

- Doesn't restart the dev server
- Doesn't modify code or kill processes — only observes
- Doesn't try to *fix* the issue, just identifies it. Reporting the diagnosis is the deliverable.
