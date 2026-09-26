---
name: push-ready
description: Get a branch to a green, push-ready state in one motion — reviews the branch diff (auto-applying confirmed findings, flagging uncertain ones for the viewer), keeps a voiced commit outline (sealing only placeholder history into one voiced commit), runs the pre-push gates through the forest viewer server (the only path that records the verdict), restacks onto fresh origin/main when the fresh gate complains, and leaves the viewer pointed at the result with the push button unlocked. Use when the user says "I'm ready for this to be pushed", "ready to push", "run the gates", "gate this branch", "green this", "prep this for the viewer", or when the work on a branch feels done and the next step is the user pushing from the viewer. Single branch or single project scope. NOT for shipping a whole forest with PR bodies and merge-order handoff (that's /land-forest), and NOT for building/splitting one (/reforest).
---

# Push Ready — sealed, gates green, push button unlocked

A branch isn't done when the code is done. "Ready to push" = voiced outgoing commits — one, or a
short outline a reviewer reads the diff by — + a **server-recorded** green gates verdict (`branch.<b>.stack-gates-green-tree` == the branch's tree
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

### 3 · Review — findings folded in before the seal

Run the `code-review` skill on the `parent...branch` diff, medium effort by default (the user can
name a level, or say "no review" to skip). Findings split by verdict:

- **CONFIRMED** → apply the fix as a NEW commit on the branch (never amend). A fix to code an
  outline commit introduced is `git commit --fixup=<that sha>` (folded in §4); a fix that is its
  own idea gets its own voiced subject and joins the outline.
- **PLAUSIBLE / unapplied** → never auto-apply. Record them for the viewer, tree-keyed like the
  gates verdict so they die with the next edit:

```bash
git config --unset-all branch.<b>.stack-review-flag 2>/dev/null || true
git config --add branch.<b>.stack-review-flag '<file>:<line> — <one-line finding>'   # per finding
git config branch.<b>.stack-review-flags-tree "$(git rev-parse '<b>^{tree}')"
```

Record flags AFTER any confirmed fixes land (the fixes move the tree). A clean review still
writes `review-flags-tree` with zero `review-flag` entries — that's the "reviewed, nothing
flagged" state. Never let a finding you didn't apply silently vanish: it's either a flag or a
line in the final report.

### 4 · Seal — keep the outline, fold the fixups

**First push only** (no open PR). The outgoing commits are the reviewer's table of contents:
`git log --reverse <parent>..<branch>` should read as a terse outline of the diff — 1–4 commits,
each one idea, subject `type(scope): subject`, a body only when one line of *why* is
non-obvious. Behavior changes sit apart from the refactors around them (the fix is the 2-line
commit a reviewer can't miss). So:

- **Fixups** (`fixup!` from §3) → fold them into their targets:
  `git -c sequence.editor=: rebase --autosquash -i <base-sha>` (non-interactive; `<base-sha>` is
  the branch's real base, never a moved ref). Tree unchanged → the verdict survives; reseat any
  children (`git rebase --onto <new-tip> <old-tip> <child>`).
- **Every subject voiced** → keep them; nothing to seal. The door and prep route both accept a
  voiced outline.
- **Placeholder history** (wip, "address review", "more fixes", or the user asks for one commit)
  → `stack-squash --unpushed <branch>` — one voiced commit beyond the parent. Squash preserves the
  tree, so an existing verdict survives sealing.

Reshaping an existing squashed branch into an outline is a rebuild from its base with per-commit
tree parity (the branch's final `^{tree}` must equal the old one) — never a code change.

**Branch with an open PR: do NOT seal.** Follow-up commits are review rounds and push as they
are (the door's `one` ward relaxes to "N follow-up commits", 2026-09-09); each subject must be
voiced (no wip/fixup). Sealing them costs the reviewer the "changes since" view.

### 5 · Gate through the server — the CLI does not record

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

### 6 · Verify + hand off

Done means `git config branch.<b>.stack-gates-green-tree` equals
`git rev-parse '<b>^{tree}'` — check it, don't assume. Any commit landed after green invalidates
the verdict; re-run. Point the viewer (`stack-review-serve <project>` reuses the live server;
`open` the URL if the user isn't already there) and report in a few lines: branch, tip SHA,
per-gate results, review flags (count + one line each), viewer URL, push button unlocked.

## Guardrails

- No push, no PRs — the user's job starts where this ends (spine hard rule).
- Never amend, never merge commits; fixes are new commits (`--fixup` for outline targets), then fold.
- A restack conflict that's real overlapping logic → stop and check with the user.
- Multi-branch: gate bottom-up; a red parent makes children's verdicts meaningless.
- Want PR bodies and a merge-order handoff too? That's `/land-forest`, not this.
