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

## P3 — Reliability paper-cuts  *(mostly stack lane — hand off)*
- Stop swallowing git errors (`|| true` around mutating ops) — fail loud on the unexpected.
- Amnesiac branches: only strip a branch's parent/project metadata *after* a successful delete
  (a delete that fails because the branch is checked out elsewhere currently leaves it invisible).
- Dedupe resolver spawns; bound/raise the 600s Claude-resolver hang.

## Sequencing
P1 now (viewer, this session). P2 + P3 are stack-lane — coordinate with that session (claude-say)
or land via the patch protocol; P2 specifically is the contract work already on that session's plate.
