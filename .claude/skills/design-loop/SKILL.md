---
name: design-loop
description: Iterate a system's design toward robust, resilient and scalable by rounds — name its principles, map each to what actually enforces it, stress every enforcer (remove it, interleave it, crash it, replay it), get an independent Codex pass, verify findings against the code, fold each into a principle and re-scan everything with it, then make the principles executable. Use when Phil says "/design-loop", "iterate on the design", "make this robust / resilient / scalable", "what principled decisions have we overlooked", "find the holes in this design", or a design that "could be lovely but has a hole". NOT a code review of a diff (/code-review, /john-hankles) and NOT a restructure into PRs (/reforest).
---

# Design loop — principles, enforcers, holes, repeat

A hole in a design is a principle nothing actually enforces, or one that is enforced only by
accident. The loop finds those by asking, for every principle, *what enforces this, and what
happens if that enforcer goes away?*

(Origin, 2026-11-03: in the enforcement ledger, `commit` took a team lock *and* relied on a
`(teamId, version)` unique index. Phil asked "can we drop the lock and let the index catch it?"
Answering that meant stating what each one guards. The index guards every write that inserts an
event; the lock guards every write. The gap between them was projection writes with no event
behind them, a silent race the lock had been hiding. The root was `commit` mixing up recording
decisions with reconciling the table. That gave a new principle: *a write must be caused by an
event you just appended.*)

Design talk only. Each round ends in findings and proposals; nothing gets built until Phil agrees
with the direction.

## The state: one design file per system

Keep the running state in a markdown file: the project's memory file, or a path Phil names. It
holds:

- **Principles**: numbered, one line each, in plain words.
- **Enforcer table**: one row per principle. Its columns are the principle, what enforces it, how
  strong that is, and file:line.
- **Round log**: per round, the findings, their verdicts, the principles they produced and what
  got encoded.

The next round starts from this file, not from memory of the conversation.

## One round

### 1 · Principles

State the principles the design is *trying* to hold. Extract them from the code and the
conversation; don't invent aspirations. One line each. A principle that needs a paragraph is
really two principles.

### 2 · Enforcer table

For each principle, name what enforces it, ranked strongest first:

1. **Database constraint**: a CHECK, unique index, FK or trigger.
2. **Type**: invalid states can't be represented.
3. **One code path**: a single entry point owns the write.
4. **Convention**: callers are expected to behave.

Flag every row at strength 4. Also flag every row whose enforcer only covers the principle
**incidentally**, meaning it exists for another reason and happens to cover this one (the lock in
the origin story). Those are where the holes are.

### 3 · Stress every enforcer

For each row, ask whether the failure is **loud or silent**. Silent failures are the findings.

- **Subtraction**: imagine this enforcer removed. What breaks, and does anything say so?
- **Interleaving**: two writers, each reading at a different moment. Walk through one concrete
  interleaving step by step; never just say "race".
- **Crash partway**: the process dies between two writes, or between commit and a side effect.
- **Deploy order**: new code against old data, old code against new data, a script that hasn't
  run yet.
- **Replay**: old records read by new code (renamed enums, removed reasons, changed payload
  shapes).
- **Deletion and retention**: cascades, re-creation under a new id, history outliving its
  subject.
- **Growth**: what is O(history) per write, and at what size it hurts.

### 4 · Independent pass: Codex

Brief Codex with the **principles and the enforcer table, not your conclusions**. The point is to
find where the table is wrong, not to confirm it. Recipe and pitfalls are in memory
`reference_codex-second-opinion-review.md`. Run it backgrounded:

```sh
codex exec -s read-only -m gpt-6.1-sol -C <worktree> -o <scratchpad>/codex-design-findings.md \
  --color never - < <scratchpad>/codex-design-brief.md
```

The brief must include:

- the system in one paragraph;
- the principles;
- the key files;
- a **DO NOT REPORT** list of everything already decided;
- the stress axes from §3;
- the ask: *decision as it stands (file:line), the principle it breaks or leaves undecided, a
  concrete scenario, a proposed principle. Rank by cost to change later, with anything baked into
  stored data or the schema first. Say plainly if an area is sound; three strong findings beat
  ten weak ones.*

Do your own pass while it runs, so you aren't anchored on its answer.

### 5 · Verify

Check every finding, yours and Codex's, against the code before telling Phil about it. A finding
is CONFIRMED (a concrete scenario traced through real file:lines), PLAUSIBLE (the scenario is
there but depends on something unverified), or REJECTED (the code already handles it; say how).
Codex output is a lead, not a verdict.

### 6 · Fold, then re-scan (the recursion)

Turn each confirmed finding into a principle, or into a sharper version of an existing one. Then
**re-run §2 and §3 on the whole system using the new principle**, not only the spot it came from.
A principle found in one corner usually breaks in two more (e.g. "writes come from appended
events" then raises the question: is the reviewed flag on the reading row a projection? Is the
external tenant one?).

### 7 · Encode

Move each principle up the strength ranking, so the next round starts from a guarantee rather
than a memory:

- **A constraint or type** where the data allows it.
- **Property tests** when the core logic is pure (a fold or a reducer):
  - generate random histories and interleavings;
  - assert that the projection equals the rebuild;
  - assert that every record still parses;
  - assert each principle as a predicate.
- **A real race test** on the real database for the concurrency rows.
- **A live drift check**: a scheduled rebuild that diffs instead of writing, and alerts on any
  difference. Silent drift becomes a loud alert.

Encoding is building, so it waits for Phil's go. Propose it as forest branches (forests.md ladder:
constraints ride the schema branch, tests ride their band).

## Report each round

- **Findings**, ranked by cost to change later, with each finding's verdict and one concrete
  scenario.
- **New or sharper principles**, and what the re-scan found with them.
- **Proposed encodings**, as branch names with one-line purposes.
- **The one question** whose answer changes the design, if there is one. Don't list every option;
  recommend one.

## When to stop

The loop is done when a round produces nothing new, or only refinements of existing principles,
and every principle sits at strength 1–3. Growth findings may stay deferred until they become a
problem ("add it when it bites"), but write down the measured threshold so the bite is a number,
not an incident.
