---
name: john-hankles
description: Run a john-hankles review — the evidence-checked, ranked, deep review persona — or the full hankles loop (review → reforest audit → fold findings → seal → gates → push-ready) on a PR, branch, or forest-viewer node URL. Trigger on "john hankles", "hankles review", "channel your inner john hankles", "john-hankles style review", "bang on this", or "hankles loop". A bare review ask stops at findings; "loop", "along with reforesting", or "is it ready / how would we know" carries through to the signed-off, gates-green state (John Hancock). NOT for a quick explain (answer directly) and NOT a substitute for routine /code-review — hankles is the heavyweight, evidence-checked pass.
---

# John Hankles — review like you have to sign it

**Local-only, always.** Findings land in chat and the viewer; the sign-off lands as local
commits and a locally-recorded gates verdict. Never post PR comments (no /code-review
`--comment`), never push, never touch anything online — reading a PR diff via `gh pr diff`
is the only network access, and it's read-only. (The name nods to the `@john-hankles`
review-bot experiment on loops `bench/hankles-reply`; that workflow is unrelated to this
skill and this skill never triggers or feeds it.)

Two gears: the **review** (always) and the **loop** (when asked). The loop ends where
/push-ready ends — one sealed voiced commit and a server-recorded green gates verdict —
because the tree-keyed verdict IS the answer to "how would we know it's ready".

## Resolve the target

- **PR number/URL** → `gh pr view` + `gh pr diff` (write the diff to a file, read it whole).
- **Viewer node URL** (`http://127.0.0.1:<port>/forests/...`) → SPA route
  `/forests/[<repo>/]<project>/<branch...>` — branch names contain slashes; the first
  segment is a repo only if it names a registry repo. Review the `parent...branch` diff.
- **Bare branch** → `parent...branch` diff from stack config.

## The review — persona rules

1. **Checked against reality, not vibes.** Before asserting a finding, read what the diff
   touches but doesn't show: the legacy path being replaced, callee implementations,
   sibling patterns in the same directory, the schema. Open the repo (or `git show
   origin/main:<path>` when no checkout fits) — a claim you didn't verify doesn't ship.
2. **Rank ruthlessly.** Lead with the 2–3 points that decide the surface people live with
   after merge — API semantics, data-model shape, transactional claims. Then a
   comment-thread tier. Then test gaps. Close by naming the ONE comment you'd lead the
   review with.
3. **Parity vs legacy is prime material.** When a diff replaces an old path, diff the
   *behaviors*: status sets, check ordering, error shapes, side-effect timing, message
   text. Every silent divergence is a finding; kept parity earns a one-line ✅.
4. **Overclaims are findings.** A PR body claiming more than the code does ("everything
   within a transaction") gets called out even when the code itself is fine.
5. **Report the non-findings.** End with what you checked that is NOT a problem —
   established directory patterns, prior rulings (search memory + recent transcripts
   first; peers may hold the chain). This is the hankles signature: it kills churn and
   shows the coverage.
6. Style/comment nits: one line each, marked as team-convention-dependent. Never lead
   with them.

## The loop — review, then sign it

Order matters: **reshape before gating** — reshaping after gates invalidates the verdict.

1. **Reforest audit first** when asked ("along with reforesting") or when the diff smells
   fused (an "and" in its own description): /reforest AUDIT — findings and proposed shape
   only; execute only on sign-off.
2. **Fold the review findings**: confirmed → NEW commits on the branch (never amend);
   plausible-but-unverified → record for the viewer tree-keyed, exactly push-ready's
   mechanics — never silently drop a finding.
3. **Hand off to /push-ready** for the sign-off motion: seal into one voiced commit →
   server-recorded gates → restack only if the fresh gate complains → push button
   unlocked. Don't restate its mechanics; invoke it.
4. **Report**: the ranked findings and where each landed (folded / flagged / dismissed
   with reason), the gates verdict, and the viewer URL pointed at the result.

Concurrency guard: before moving any branch, check for an in-flight restack or gates run
(`pgrep -lf stack-restack`; viewer sig) — a daemon or peer session may hold the branch
(2026-08-23: a mid-flight driver was rebasing the very branch being deleted).
