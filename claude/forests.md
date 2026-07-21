# Git Branch Forests

Think in **forests, not stacks** — a linear chain is just the degenerate case. Branches form a DAG: each has one git `parent` (its rebase base), and may **fan out** (many children) or **fan in** (carry several independent base branches at once). Claude manages this plumbing — Phil delegates it and runs no stack-specific commands.

**Fan-in is the default; everything else is the exception you justify.** The unit of work is one self-contained capability that compiles on its own — each forks off `main` as its own base PR and merges on its own schedule. Integrators that need several bases converge them with `requires` (fan-in). The north star is **reviewability**: a reviewer should hold an entire PR in their head in one sitting. Maximizing independently-mergeable bases is how you get there — it's the most scalable, maintainable way to ship. When unsure, split: more small bases beats one fused branch.

**Before adding code to a branch, ask: is this its own capability?** If a change stands on its own — a generic helper/primitive, a different layer, a separate entity or concern — and isn't the branch's core thesis, it belongs on its *own* base (fanned in), not folded into whatever branch happened to need it first. *Example: a generic `openWriteStream` S3 helper used by a restore engine is its own base — the engine chains on it — not a commit buried inside the engine.* Folding it in "because that's where I needed it" is the anti-pattern; the test is the capability, not the caller.

**Chaining (a linear `parent` line) and co-location are the exceptions** — reach for them only on a *real* dependency: a branch that genuinely won't compile or make sense without its parent. If two capabilities don't depend on each other (e.g. a Valkey cache vs. a JobStatus query change), each forks off `main` and merges on its own schedule — do NOT chain one behind the other just to make a line. Linearizing independent work forces a false merge order and blocks each PR on the others. The integrator that needs both records them as fan-in deps.

## Two relationships per branch

- **`parent`** (single) — the git base this branch is rebased onto. `git config stack-branch.<name>.parent <parent>`.
- **`requires`** (multivar, optional) — fan-in deps: branches this one *carries* (cherry-picked) beyond its `parent`. Metadata only — the `parent...child` review diff is unchanged; `requires` drives the forest viewer's inbound edges and restack re-sync. `git config --add stack-branch.<name>.requires <dep>`.

A pure line uses only `parent`; fan-in adds `requires`. **Never any git merge commits** — fan-in is metadata over linear history (carried cherry-picks), so squash-merge still drops redundant commits cleanly on rebase.

**Chain vs fan-in — the one-dep test.** If a branch needs exactly ONE other branch to land first because it actually uses its content (compile, build, or runtime), that's a dependency: chain it (`parent = <dep>`). `requires` is reserved for a branch converging **two or more** independent bases — `parent` = one of them, `requires` = the rest. Exactly one `requires` on a main-rooted branch is a mis-encoded chain, and its carried cherry-pick makes the branch's review diff re-review the dep (bit us on the ts7 webpack/extension-imports branch, 2026-07-13).

## Branch purpose

Every branch carries a one-line **purpose** — what it's for / what it lays the foundation for — stored as git's native **branch description** (`git config branch.<name>.description`, a.k.a. `git branch --edit-description`). Git owns it, it's free to read, and it shows in the forest viewer under each node.

Setting and refreshing the purpose is **part of the forest operation itself, not an optional follow-up** — it belongs in the same motion as setting `.parent`, exactly like a description is local git config that never reaches GitHub (it's not in the PR body, so there's no "should this go upstream?" question — just set it). **Never ask permission to set or refresh a purpose, and never offer it as a separate step — do it silently as part of the change.** Asking "want me to set descriptions?" after a forest edit is the anti-pattern this section exists to kill: the answer is always yes, so don't ask.

- **Set it the moment a branch exists** — `git config branch.<branch>.description "<thesis>"`. A freshly-created branch with no description is an unfinished operation. When Claude creates branches for a stack, every one gets its purpose before moving on.
- **Write it in plain language — what the branch *does*, not how it's coded.** Say it the way you'd tell a teammate: drop raw identifiers (`markLocked`, `getOrFetch`) and terms-of-art (`idempotent`, `monotonic`, `short-circuit`) for the behavior they name; keep forest vocabulary (`requires`, fan-in, convergence) — that's structure, not jargon. The purpose seeds the forest viewer and the PR-body drafter, so a reader who doesn't know the code should still grok where the branch sits. Bake this register in at forest-generation time, not as a later de-jargon pass.
- **Keep it short and terse — one verb-first line, thesis only.** A description is scanned, not read. Write the single thing the branch is for (`adds the queries the membership repair needs`), NOT an "and X, and Y, and Z" inventory of every function or file it touches. The per-file detail lives in the diff, not the description. Same terseness carries to PR bodies: one short line of purpose plus a plain numbered forest-position list (`Part of <project>: 1. [this branch]  2. models  3. …`), not prose. Phil's default; err shorter.
- **Any ancestry change invalidates descriptions — refresh them in the same step.** Reparent, `rebase --onto`, restack, rename, or a `requires`/fan-in change can make a description's account of the branch's parent line, deps, or role go stale. A description that names a parent/inheritance the branch no longer has is a *bug introduced by the operation*, the same as leaving `.parent` wrong. Re-read every touched branch's description after an ancestry edit and fix the ones that no longer match. Treat "all touched descriptions accurate" as part of the operation's definition-of-done — verify it before reporting the reshape complete.
- **Keep it current on scope/repurpose too** — when a branch is repurposed or its scope shifts, update the description. A stale purpose is worse than none.
- **The forest section in each commit body bakes at prep time ONLY — never refresh it mid-flight.** A branch's commit body carries a machine-written section (`stack-commit-body <branch>`: its place in the merge order and what it builds on). A rebase replays the message verbatim, so any reforest leaves it stale — and that's fine: the viewer renders the story from live config, and the push flow folds a fresh section into the commit at prep, so a stale plan never reaches origin. The old doctrine (regenerate bottom-up on every ancestry change) is retired 2026-07-20: each regeneration rewrote tips mid-flight, orphaning children and forcing a reseat cascade of its own — maintaining derived state was the disease, not the cure. Descriptions still refresh with ancestry changes (they're config, free to rewrite); commit bodies deliberately do not.
- The viewer reads the description for **free** (no LLM). A "suggest" button can draft one from the diff (opt-in, haiku) which you then save as the description — **generation never runs automatically**, nothing burns tokens on its own.

## Creating branches

Always create from the intended parent (the branch this one stacks on top of). Use plain `git checkout -b`:

```bash
git checkout <parent-branch>           # switch to the intended parent first
git checkout -b <new-branch-name>      # child branch forks from current HEAD
```

The parent relationship is **implicit in the fork point** — git does not track it natively. Two places need to know the parent explicitly:

1. **PRs**: an independent base targets `main`; a stacked child targets the nearest ancestor with an **open PR** (so the review diff stays the branch's own work — GitHub retargets the child to main itself when the parent merges), falling back to `main` when no ancestor PR is open. The viewer's compare links prefill this base (2026-07-19). New work always merges after the already-open PRs. (Never let tooling open PRs — that's manual.)
2. **Rebase after parent changes**: `git rebase <parent>` (or `git rebase --onto <new-parent> <old-parent>` when moving a branch).

Record the parent in the PR body when opening (e.g. "Stacked on: #1234") so reviewers can see the order. And **set the branch's purpose right after creating it** — `git config branch.<new-branch-name>.description "<one-line thesis>"` — so the intent is captured while it's fresh.

**Structure changes atomically** — each branch/commit is a single, self-contained change. When working on multi-part changes, decouple them into separate branches in the forest, ordering zero-dependency changes first.

## Common tasks

| Task                       | Command                                                     |
| -------------------------- | ----------------------------------------------------------- |
| Create child branch        | `git checkout <parent> && git checkout -b <name>`           |
| Fork an independent base off main | `git checkout main && git checkout -b <name>` (no parent → roots off main) |
| Add a fan-in dep           | `git config --add stack-branch.<name>.requires <dep>`       |
| Set/update a branch's purpose | `git config branch.<name>.description "<thesis>"` (a.k.a. `git branch --edit-description`) |
| Tag a branch's forest membership | `git config stack-branch.<name>.project <project>` + `git config --add stack-project.<project>.branch <name>` (the viewer reads these) |
| Review the forest (live)   | `loops stack web [<project>]` — Phil's browser viewer, on the repo's own port (`stack-review-port` prints it; read-only; reads git config per request). Claude doesn't drive it; it just keeps the config correct. |
| Update branch after parent change | `git rebase <parent>`                                |
| Move branch to new parent  | `git rebase --onto <new-parent> <old-parent> <branch>`      |
| Restack whole forest after a merge | raw git — snapshot SHAs, ff `main`, `rebase --onto` bottom-up (see *Restacking* below) |
| Create PR (manual — Phil opens) | reference only: `gh pr create --base <nearest-open-ancestor-PR-branch, else main> --head <branch>` — never run against origin |
| Squash commits             | `git reset --soft <parent> && git commit`                   |
| Health-scan the forest     | `stack-doctor [<project>]` (read-only; `--orphans` = problems only) |
| Reclaim config a dead branch left | `stack-doctor --prune` (`--dry-run` previews)         |

## The forest config is hand-maintained (the viewer reads it)

The review surfaces — `loops stack web` (the browser viewer), `loops stack review` (nvim), and `loops bless` — are **read-only consumers of git config**. They render whatever these keys say; nothing writes them automatically. So Claude maintains them by hand:

- `git config stack-branch.<name>.parent <parent>` — the rebase base. Set at branch creation; update on every rebase-onto-new-parent, on rename, and when rewiring a dropped node's children.
- `git config stack-branch.<name>.project <project>` — per-branch project tag. Set at creation. **It rots** (see below).
- `git config --add stack-project.<project>.branch <name>` — the project's branch list. **It rots** — renaming/deleting a branch leaves a dangling entry. Fix by hand (`--unset` the old value, `--add` the new); verify with `git config --get-all stack-project.<project>.branch`.
- `git config branch.<name>.description "<thesis>"` — the branch purpose.

**Why every `stack-*` key rots: it lives outside the one namespace git manages.** `git branch -D <b>` deletes the whole `branch.<b>.*` section (any key under it, even one you invent); `git branch -m a b` moves it. Our `stack-branch.<b>.*` / `stack-project.<p>.*` get neither, so they outlive the branch they describe — 36 dangling keys had piled up in loops by 2026-07-16, and a shipped forest kept its focus slot. *(This list once claimed `.project` was "self-healing: it dies with the branch." It never did — that false promise is why the rot went unseen. Don't re-add it.)* The real fix is to move this metadata under `branch.<b>.stack*` and let git GC it for free; deferred — it touches every reader.

**Sweep the rot**: `stack-doctor --prune` (`--dry-run` previews) drops config whose ref is gone, registry entries + `requires` naming it, and a project's keys once no member survives. Idempotent; a project mid-setup keeps its keys. `stack-restack` already does the project half when contraction empties a forest, so shipping self-cleans — reach for `--prune` for branches that died some other way (`git branch -D`, scratch `wt-*` worktrees).

**Rename checklist** (all four move together): `git branch -m`, then migrate `.parent` + `.project` keys and the `stack-project.*.branch` entry, and re-point any child's `.parent`. The branch *description* follows `git branch -m` automatically; the `stack-*` keys do **not** — that asymmetry is the namespace gap above, and this checklist exists only to do by hand what git does for free under `branch.<b>.*`.

## Restacking after a merge — first principles (raw git)

When the bottom of a forest merges (or `origin/main` advances), rebase every member onto fresh `main` **by hand** — no wrapper. The whole walk is three moves:

1. **Refresh main** (usually not checked out, so move the ref directly): `git fetch origin main && git branch -f main origin/main`.
2. **Snapshot each branch's current SHA** *before* moving anything — descendants need their pre-rebase parent SHA as the `--onto` cut point.
3. **Rebase bottom-up (topological)** — roots onto `main`, then each child onto its *moved* parent, replaying only that branch's own commits: `git rebase --onto <new-parent> <old-parent-sha> <branch>`. Do each rebase in the worktree where that branch is checked out (a branch checked out elsewhere can't be rebased from here); for an unchecked-out branch, add a throwaway worktree on it.

After the walk — or after **any** rebase that empties a branch, even a one-branch forward-rebase — **contract the graph, don't leave the empty node.** A branch whose `git diff <parent>...<branch>` is empty (or that is now an ancestor of `main`, i.e. its work squash-merged) is done: drop it (`git branch -D`) and rewire its children's `parent` onto the dropped node's parent (see the config checklist above). Contracting is what *preserves* graph integrity — children reconnect to a live base — so it beats leaving a zero-diff branch hanging; an empty node is the confusing state to avoid. **Do this as part of the rebase, then summarize — never just report "the branch is now empty" and stop.** Squash-merged commits won't match `origin/main` by SHA — the rebase drops them cleanly (both `parent` and carried `requires`).

A rebase is also a **comment-review checkpoint.** Any branch you rewrite, re-read its `parent...child` diff against the comment gate (*Comments* in the style file) and trim anything that no longer earns its keep — reforesting is the free moment to delete narration that survived the first pass.

Conflicts: resolve them yourself, in the rebase — don't bypass with `--skip`/`-X`. Treat a real (overlapping-logic) conflict as a signal to check with Phil rather than guess.

> The viewer still has a one-click **Restack** button that drives the `stack-restack` script in the background — that's Phil's to press, not Claude's plumbing. Claude restacks from first principles as above.

## Forest hygiene

- After a base merges, rebase the forest onto fresh `origin/main` by hand (see *Restacking*), drop the now-redundant node, and rewire its children — **the graph contracts by that node**, and keeps contracting as each independent base lands. Squash-merged commits won't match `origin/main`; the rebase drops them cleanly (both `parent` and carried `requires`).
- **History stays linear — no merge commits**, even with fan-in (it lives in `requires` metadata + carried cherry-picks). The viewer's integrate preview builds an *ephemeral* octopus ref only as a whole-feature view, never a branch base — Phil's tool, not Claude's plumbing.

## PR design

Each branch is **one reviewable unit — a single capability that compiles on its own**, named with one verb (`add X`, `record X`, `emit X`, `use X in Y`, `remove X`). Size tracks concern-count, not a line budget: prefer 3× 80-line PRs over 1× 200-line PR — but a cohesive primitive + its tests is fine even at ~250. The reference standard is **nalanj's PRs**: a feature shipped as ~7 single-verb stacked PRs, tests co-located, each metric its own tiny PR.

### Ordering & shape

- **The canonical project skeleton is a layer-per-band line**: **cleanup → queries + tests → models + tests → wiring + tests → endpoints + tests** (endpoints only when it's not tRPC; tRPC routers are wiring). Most features fall straight onto this ladder — reach for it first, and let a band be empty (no models layer, say) rather than fusing two layers to fill it. Tests ride in the *same* band as the code they cover, never a band of their own.
- **A foundational cleanup goes FIRST, at the bottom — not last.** The order is *by dependency*, so a refactor that later bands build on (extract a helper, move a value into `AppEnv`, add a column) is the base off `main` that the queries/models chain onto. "Cleanup last" only applies to a *post-hoc* tidy that nothing downstream depends on. When a band defaults to `X` from a primitive the cleanup introduces, that primitive is a real dependency → chain, and it sits underneath.
- **Independent capabilities fork off `main` as siblings**, not chained — each independently mergeable. Only chain on a real dependency.
- **Integrators fan in**: a branch that needs several independent bases sets `requires` on them (and carries their commits), rather than forcing the bases into a false line.
- **Tests co-locate** with the code they test (`createX` with queries, `fakeX` with models).
- **Observability/metrics get their own small PRs.**

### Boundaries

- One layer (query / model / wiring) for one entity or concern per branch.
- UI branches separate from API branches, even for the same feature.
- Changes across 3+ unrelated directories → too big, split it.
- A branch that only makes sense *with* its child → merge it into the child.

### What NOT to do

- Don't put business logic in query branches (status checks, authorization, cross-entity cascades).
- Don't mix query expansions + tRPC endpoints + UI components in one branch.
- **Don't chain independent base capabilities into a line just to avoid fan-in** — that blocks each PR on the others' merge order.
- Don't add a column/migration in a middle branch when a schema branch exists — prepend/extend the schema branch.

## Reviewing changes

Three tools, different jobs — don't conflate them. `review` (nvim) and `web` (browser) are **not the same command**:

- **`loops stack web [<project>]`** — the **primary, live review surface** (the blessing-ledger server, on the repo's own port — `stack-review-port` prints it; loops is :62497 today. Per-repo so several repos can be forested at once; :62333 is only the legacy not-in-a-repo fallback — a dead end from a worktree). Renders the whole forest in the browser: tree rail, graph map, per-node `parent...child` diffs, since-blessed deltas, and click-to-bless. Reads git config live per request. This is where Phil reviews — default to it.
- **`loops stack review [<branch>]`** — *(legacy, local)* stack-stepping in **nvim diffview**, one `parent...child` link at a time. Doesn't know worktrees exist. Use only for offline/local stepping; the `--html` (/tmp browser tabs) flag is deprecated — use `loops stack web` instead.
- **`wt [base-branch] [--html|-H]`** — solves the **worktree-discovery** problem. fzf-picks across sibling worktrees and shows the picked branch's *full* cumulative diff vs `base` (default `main`), including uncommitted working-tree changes (`--imply-local`). Not stack-aware — a 6-branch stack shows as one giant diff.

Decision rule:
- Reviewing/blessing a whole forest or stack → `loops stack web` (default)
- Single-branch feature, or scanning across many worktrees → `wt`
- Offline, no browser, want nvim stepping → `loops stack review`

### Claude inside the viewer (it's no longer purely read-only)

The viewer started as a read-only config consumer, but the Solid rewrite (`scripts/viewer-solid/`) added affordances that **mutate state and spend tokens**. Know they exist before you assume a click is free:

- **Per-file diff card** — each `.entry` carries `⎘ copy ref` (clipboard: `` `path` (on branch `branch`) ``, for pasting into a chat) and `✦ chat` (a right-side drawer that streams a headless **read-only** `claude -p` token-by-token over SSE; seeded with the file's diff, multi-turn via `--resume`). Backend: `srv/chat.py` → `POST /chat`. It's allowlisted to `Read`/`Grep`/`Glob` — it can read the branch's tree but never edits/runs/commits.
- **Mutating actions**: `/bless`, `/checkout` (moves the **main working tree** onto a branch), `/squash`, `/restack`, `/restack-all`, `/sync`, `/prep`. These rewrite history / move HEAD.

**Never curl-probe a mutating endpoint with a real branch name to "test" it.** `POST /checkout` will yank `~/coding/loops` off whatever branch another session is live on — it bit us. To check a route is wired, probe with a nonexistent branch (e.g. `__probe__`) or an empty body and assert it returns 400/404, never a real value.

**Bouncing the viewer server is safe and cheap — do it freely, no permission needed.** Its state is durable by design (crash-only, 2026-07-12): gates-green persists in git config (`stack-branch.<branch>.gates-green-tree`, keyed by TREE sha so a message reword keeps the verdict) and every detached gates run writes a sidecar (`$TMPDIR/stack-gates-<branch>.job.json`) that a reborn server re-adopts by pid — a restart never relocks push, never loses a running typecheck, never steps on other sessions. Bounce = kill the pid, then `stack-review-serve --ensure` from any worktree of the repo. One taboo: never hand-write the `gates-green-tree` config key for a real branch — that forges a green verdict without running the gates.
