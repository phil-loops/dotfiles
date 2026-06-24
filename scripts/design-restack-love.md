# Restack engine — three improvements (lane-aware plan)

**Status:** proposed 2026-06-24. Grounded in failures hit this session.
**Lanes:** `srv/restack.py` + `Hearth.tsx` = **viewer** (ours). `stack-restack` / `stack-restack-all`
/ `rebase-classify` = **stack** (held by a live session; patch-protocol or hand off).

## P1 — Stoppability  *(viewer lane — build directly)*
**Problem:** a *running* restack can't be stopped from the UI. `/restack-abort` only clears a
*parked* conflict (409s while running). `stack-restack-all` traps `SIGTERM` (to release its lock)
and doesn't exit, so a normal kill is ignored — needed `SIGKILL` by hand this session.

**Design (no stack-script edits needed — SIGKILL is untrappable):**
- `srv/restack.py`: `POST /restack-stop` → for each `_drivers()` pid: `SIGTERM`, brief grace,
  then `SIGKILL` survivors; then `_clear_park()` (aborts the in-progress rebase + drops state);
  then remove the now-stale `stack-restack.lock`. Returns `{ok, stopped:[pids], project}`.
- `Hearth.tsx`: when `running`, show a **■ stop** button → `/restack-stop` (with error surfacing,
  like the abort fix). Distinct from "abort the race" (which only clears parks).
- *(stack lane, optional later via patch):* make `stack-restack-all`'s `INT/TERM` trap actually
  abort the current rebase + `exit`, so a graceful `SIGTERM` works without escalating to KILL.

## P2 — Merged `requires` dep makes its integrator grind a conflict  *(stack lane — hand off)*
**Problem:** the pre-pass contracts a merged dep NODE, but the integrator still **carries** that
dep's cherry-picked commits. They replay on the new base; if the dep drifted before merging
(this session: `numeric-enum/integrate` carried `1_000/200` vs landed `2_000/Event`) it's a real
conflict the conservative resolver escalates.

**Design (for the stack-lane session — overlaps its `rebase-classify` CONTRACT work):**
- When a dep is classified already-merged (exit 20), record the files it owns. While rebasing an
  integrator that `requires` it, on a conflict limited to those files take the **landed (`--ours`,
  the rebase base = main) side** automatically — the merged dep's shipped content is authoritative.
  Escalate only if the integrator *independently* modified those files (its own non-carried commit
  touches them). This makes Phil's "merged ⇒ should just work" hold even when the dep drifted.

## P3 — Reliability  *(mostly already hardened; one wart fixed)*
On reading the live code, the flagged paper-cuts were **already handled**:
- **Amnesiac branches** — fixed: a failed `git branch -D` `continue`s *before* stripping
  parent/membership (`stack-restack` ~1184–1192).
- **Duplicate resolvers** — prevented by the single-flight `STACK_RESTACK_LOCK_OWNER` reentrancy
  (`stack-restack` ~133–135).
- **Claude-resolver hang** — bounded: `run_bounded` kills the resolver at `RESOLVE_TIMEOUT` (600s,
  ~439) and escalates.
- `|| true` swallowing is mostly intentional (`config --unset` on maybe-absent keys); no clear bug
  to fix without risky churn — left alone.

**Fixed:** `stack-restack-all` trapped `INT/TERM` to *release the lock* but didn't exit — so a plain
kill was ignored and `/restack-stop` had to SIGKILL. Now an `on_signal` handler aborts the in-flight
rebase, drops the parked state, releases the lock, and exits — graceful stop works.

## P4 — drift fix: rebase from the merge-base, not the parent's stale tip  *(stack lane)*
`stack-restack` cut the rebase at `OLD_PARENT_SHA` (the parent's snapshot tip). For a **drifted**
branch (forked off main, not its declared parent — so that tip isn't an ancestor), `OLD..BRANCH`
re-includes a COPY of the parent's commits → the rebase re-applies them and self-conflicts (this is
exactly why `fix forest` parked on `metric-cells`). Fix: when the parent tip isn't an ancestor, cut
at `git merge-base <parent-tip> <branch>` instead, so only the branch's real divergence replays and
git drops patch-identical carried parent commits. No-op for properly-stacked branches (merge-base ==
parent tip). DONE — verified stacked=no-op / drifted=merge-base.

## Status (2026-06-24)
- **P1 — stoppability:** DONE (`0722de2`) — `/restack-stop` + Hearth ■ stop.
- **P2 — contracted-dep drift:** DONE (`bdb92b1`) — auto-take main's landed version; verified.
- **P3 — reliability:** the concrete items were already hardened; the `stack-restack-all` TERM-trap
  wart is fixed. Nothing else worth churning a critical script for.
