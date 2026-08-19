---
name: push-ready
description: Get a branch to a green, push-ready state in one motion — seals the outgoing commits into one voiced commit, runs the pre-push gates through the forest viewer server (the only path that records the verdict), restacks onto fresh origin/main when the fresh gate complains, and leaves the viewer pointed at the result with the push button unlocked. Use when the user says "I'm ready for this to be pushed", "ready to push", "run the gates", "gate this branch", "green this", "prep this for the viewer", or when the work on a branch feels done and the next step is the user pushing from the viewer. Single branch or single project scope. NOT for shipping a whole forest with PR bodies and merge-order handoff (that's /land-forest), and NOT for building/splitting one (/reforest).
---

# Push Ready — sealed, gates green, push button unlocked

A branch isn't done when the code is done. "Ready to push" = ONE voiced outgoing commit + a
**server-recorded** green gates verdict (`stack-branch.<b>.gates-green-tree` == the branch's tree
SHA). Restack mechanics live in `claude/forests.md` (*Restacking after a merge*) — apply, don't
restate.

## The motion

### 1 · Resolve the target

Explicit arg → that branch, or every branch of that stack-project (bottom-up, `stack-merge-rank`
order). No arg → the branch this conversation has been working on. Run everything from the
worktree that has the branch checked out — never yank the user's main checkout.

### 2 · Preflight

`git status` in that worktree as its own step. Work-in-flight belonging to the branch gets a
clean NEW commit (never amend); unrelated dirt stops the motion — say what's there. Then the
description gate: re-read `branch.<n>.description` against the `parent...branch` diff — anything
the description doesn't say is a split point, flag it before gating. `git fetch origin main`;
if behind on deploy-critical, restack now (forests.md mechanics) rather than letting the fresh
gate bounce.

### 3 · Seal

`stack-squash --unpushed <branch>` — one voiced commit beyond the parent. If it reports nothing
to squash, the branch is already sealed; move on. Squash preserves the tree, so an existing
verdict survives sealing.

### 4 · Gate through the server — the CLI does not record

`stack-gates` run directly prints a verdict but writes nothing; only the viewer server records
`gates-green-tree`, and an unrecorded verdict leaves the push button locked. So:

```bash
curl -s -X POST http://localhost:$(stack-review-port)/gates \
  -H 'Content-Type: application/json' -d '{"branch":"<b>","detach":true}'
# then poll http://localhost:$(stack-review-port)/gates-progress until done
```

(No live server → `stack web <project>` starts one.) Triage failures: **fresh** → restack +
re-run; **format** → `stack-gates <branch> --fix`, commit as a new commit; **typecheck/tests** →
fix honestly, new commit, re-run. Never hand-write `gates-green-tree` (spine hard rule).

### 5 · Verify + hand off

Done means `git config stack-branch.<b>.gates-green-tree` equals
`git rev-parse '<b>^{tree}'` — check it, don't assume. Any commit landed after green invalidates
the verdict; re-run. Point the viewer (`stack-review-serve <project>` reuses the live server;
`open` the URL if the user isn't already there) and report in a few lines: branch, tip SHA,
per-gate results, viewer URL, push button unlocked.

## Guardrails

- No push, no PRs — the user's job starts where this ends (spine hard rule).
- Never amend, never merge commits; fixes are new commits, then re-seal.
- A restack conflict that's real overlapping logic → stop and check with the user.
- Multi-branch: gate bottom-up; a red parent makes children's verdicts meaningless.
- Want PR bodies and a merge-order handoff too? That's `/land-forest`, not this.
