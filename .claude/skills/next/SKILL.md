---
name: next
description: Decide what to build next on canopy (the forest viewer) — reads the viewer's feature tracker (`canopy-todo`, ~/.dotfiles/canopy/todo), closes out items that already landed, ranks the open queue by value against cost, checks that the top picks can be built in a principled way (and makes the design fix the first step when they can't), and writes concrete next steps into each top item. Use when Phil says "what's next", "/next", "prioritize", "what should we work on" about the viewer, or "/next <item-id>" to plan one item. Scope is the viewer and its tooling only — not Loops product work.
---

# /next — rank the viewer's queue, check the design, lay out the steps

The tracker is the one list of viewer work: `~/.dotfiles/canopy/todo/<id>.md`, read and written only
through `~/.dotfiles/scripts/canopy-todo` (fields and kinds: its `--help` and `scripts/srv/todo.py`).
The Todo page (`/v2/todo`, `g o`) shows the same files live. This skill doesn't start work: it ends
with a ranked queue, steps written into the top items, and a short report. Phil says go.

`/next <id>` skips to steps 4–5 for that one item.

## 1 · Read the state

- `canopy-todo ls --json` and `canopy-todo check` (fix what check reports before ranking).
- What landed since items were written: `git -C ~/.dotfiles log --since=<oldest open item's updated> --oneline -- scripts/ wiki/loops/canopy* .claude/skills/next`.
- What hurts in daily use: `curl -s 127.0.0.1:62497/telemetry/summary` — commands over budget
  (`over`, p95 vs budget), high refusal/failure rates, never-used commands. Read-only GET; never
  probe a mutating endpoint.
- The design page for each area you rank near the top: `wiki/loops/canopy-v2*.md`.

## 2 · Triage

- **Landed** → `canopy-todo done <id> "<sha> — <what proves it>"`. Verify in code, not from the
  subject line alone.
- **Waiting** items whose event happened → back to open (`canopy-todo set <id> state=open waiting=`).
- **Found in telemetry and not tracked** (a command over budget, a refusal spike) → `canopy-todo add`.
- **L items in the top ten** → split: add the pieces, drop or re-scope the parent. A ranked item is
  something one session can finish.

## 3 · Rank

Rank the open queue best-first and write it with `canopy-todo rank <id> <id> …` (the top 10–15; the
rest stay unranked). Order by value over cost, using these — say which one decided each top pick:

1. **Decisions Phil can clear in a line come first** when they unblock work (`kind = decide`). They
   live in their own "Needs you" section, so rank them among themselves too.
2. **Bugs he hits daily** before features in the same area — telemetry use count × how far over budget.
3. **Unblocking**: an item others name in `blocked_by` rises with each one it frees. Never rank an
   item above its blocker.
4. **Decay**: things that rot if left — a feature half-landed, a flag that's built and off, a stale
   design page.
5. **Cost**: S beats M at equal value. L doesn't get ranked (step 2 split it).

## 4 · Check the design of each top pick

Read the code each top-3 item touches. Then hold the obvious implementation against canopy's
invariants, and say which ones govern:

- **One source of truth.** No second copy of state. Derive it (the tracker links forests and PRs, it doesn't copy them).
- **Every action is a registry command**: keys, the space menu, the `?` sheet, telemetry and undo
  (`inverse`) come from one declaration. On-page key hints use `keyOf(id)`. A key means one thing on
  every page (`bindings.test.ts`).
- **Data reaches the client through `/state` domains**, with optimistic writes through the runner and
  a `settled` check against the server's copy. Only `sync.ts` touches the network.
- **Outward actions only through Phil**: the viewer never pushes or posts to GitHub on its own.
  Review writes stop at his pending review.
- **Tests load the real thing**: the registry, the real file, a fake GitHub. They don't scrape the
  source. Pure logic lives in pure modules with tests beside it.
- **Measured**: a new command has a budget class; a new surface has a `data-paint` marker.
- **Quiet UI**: outcome buttons, rails don't grow buttons, ambient stays quiet, sticky not modal.
  See the viewer-grammar memories.
- **Simple over generic; no churn for purity.**

If the straightforward build breaks one of these, the first next step is the design change. If two
invariants conflict, write that down as a `decide` item for Phil instead of picking quietly.

## 5 · Write the next steps

For each top-3 item, pipe 3–7 steps into `canopy-todo steps <id>`:

```
Design: <the invariant(s) that shape this, and the decision made>
1. <file(s)> — <change>; test first where there's logic (<test file>)
2. …
Verify: <npm test / typecheck / Puppeteer check / fixture harness> — <what you'll see>
Done when: <observable outcome>
```

## 6 · Report

Lead with the pick. Keep it to:

- **Next:** the top item: title, why it beat the others in one line, size, first step.
- **Then:** #2 and #3, a line each.
- **Needs you:** each open decision as one line, with the command or answer that clears it.
- **Closed / added / split:** a line each, with evidence for anything marked done.

Then stop. When Phil says go, set the item to `doing` (`canopy-todo set <id> state=doing`), build
it, and `canopy-todo done <id> "<sha> — …"` when it lands.
