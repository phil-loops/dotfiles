# How this file is organized

Hard rules and behavioral defaults live here, always in view. Mechanics live in the imported topic files at the bottom. When adding guidance: an invariant goes under *Hard rules*, a procedure goes in the matching topic file, and a dated war story gets compressed to a one-line parenthetical (the full story belongs in memory, not here). **Every addition contracts**: fold the lesson into the existing rule that should have caught it and delete what that makes redundant — a new section is a last resort, net growth needs a reason, and guidance that only accretes dilutes every rule already there. **A rule never lives only in memory**: a feedback memory that states a rule is promoted here (usually as an instance folded into a *Principle*) in the same motion, and the memory keeps the story with `promoted-to:` in its metadata — memory reaches one agent, these files reach every agent (`scripts/agent-rules` builds Codex's `AGENTS.md` from them; `agent-rules --check` fails on drift or an untagged feedback memory). Claude-only mechanics sit between `<!-- claude-only -->` and `<!-- /claude-only -->`.

# Hard rules

Non-negotiable, in every repo, regardless of what a task seems to call for.

**Pushing & PRs**

- **Never push branches, open PRs, or write to GitHub in any form** (comments, reviews, labels, PR-body edits, deleting remote branches) **— Phil handles all of it himself**, and never let tooling or an agent you brief do any of it: context reaches a PR only through a prefilled form Phil submits (2026-10-28: a briefed Codex opened #11269). Claude's job ends at a prepped local branch + a drafted PR body — and when the branch is bound for a push (a new PR against main, or new commits onto an open PR), "prepped" includes sealed + server-recorded gates-green (`/push-ready`): run the gates unprompted, and any commit landing on a gated tip re-runs them. (Remote topology: loops topic file.)
- Committing locally is fine — make clean, self-contained commits.

**History**

- **Never amend commits** — always create new commits. PRs are squash-merged, so local history noise doesn't matter.
- **Never add Co-Authored-By lines.**
- **History's rules follow who can see it.** *Local, unpublished:* linear — rebase freely; fan-in lives in `requires` metadata + carried cherry-picks, never a merge commit. *A published PR branch* (reviews, CI and checkouts reference it): append-only — new commits on top; a moved base catches up by a catch-up merge of the base's new head (so the PR diff stays its own change); never `git push --force` it, nor any branch another session may be live on, except an explicit replace of an unreviewed draft — leave a cosmetically-wrong message alone. *main:* linear by squash-merge. (2026-11-17: a GitHub-side rebase plus local restacks of a published stack ended in a hand-run force push.)

**Production & cloud access**

- **Never run `aws-vault`, `kubectl`, or any command that assumes an AWS role or reaches a live cluster (prod *or* staging)** — Claude reads infra facts from the repo (`k8s/`, `terraform/`) and, when only the live environment knows, hands Phil the `! <command>` to run himself. (2026-10-12: tried `kubectl get nodes` via aws-vault to look up node types.)

**Dotfiles**

- **Never `zsource` / `git add -A` / `git stash` in `~/.dotfiles`** — a whole-tree op sweeps Phil's concurrent WIP into yours (test old code in a `git worktree add --detach` instead). `git status` as its own step, then stage explicit paths (mechanics: dotfiles topic file).
- **Never put scripts in `~/bin`** — they go in `~/.dotfiles/` so they're version controlled.

**Forest viewer & gates**

- **Never curl-probe a mutating viewer endpoint with a real branch name** — they rebase, push, restack and seal real branches (`/sync`, `/prep-push`, `/push-origin`, `/restack`). Probe with a nonexistent branch (`__probe__`) or empty body and assert 400/404.
- **Never write a verdict key by hand — any `stack-gates-*` or `stack-review-*` key** — they're the viewer server's record of a run (`POST /gates`, `POST /review`) or of Phil's click (a gate skip, a waiver); writing one forges "gated" or "reviewed". Any edit to a reviewed branch's own diff means a new review run; a restack under it keeps both verdicts. (2026-11-04: stamped review-flags-tree on three unreviewed rewrites; a dropped guard reached the PR. `verdict-key-guard` hook refuses the habitual path.)

# Principles

Most rules below and in the topic files are instances of these. When a new lesson arrives, find the principle it instances and fold it in as a parenthetical example.

1. **Touch only what you can name exactly** — paths and PIDs you recorded creating, explicit pathspecs, rows selected by name. Never a pattern (`pkill`, a worktree glob, `pane_current_command`), a position, or a whole-tree op in a tree someone else shares (`add -A`, `stash`, recursive `du` over `~/.cache` or `$HOME`, multi-step git in `~/coding/loops`, which Phil drives from GH Desktop). Never switch the branch of a worktree you didn't create for that purpose; editors and canopy are anchored to it. A branch you didn't build has an owner (worktree holder, tracker claim, live session): hand the edit to them. Liveness is a process's children, and a cull is a list you present, not a kill.
2. **An observation is stale by the time you act on it.** Re-read ground truth at the moment of the mutation or the diagnosis: the tip and reflog right before a rewrite (another session's `stack-reword` may have just landed); `git fetch` + `gh pr list --head <b>` before any seal or rebase ("unpushed" is a fact about a moment); GitHub's MERGED verdict, never a locally empty diff, before contracting a node; `git log main..origin/main` and the failing file's log before diagnosing red CI or a bug in merged code.
3. **Authority is Phil's direct, current, imperative word.** "I feel like X" and "maybe we should" are questions — assess, don't execute. A past one-off approval or "no roadblocks" never lowers a safety or resource guard: pause and ask. Outward actions (GitHub, pushes, Phil's desktop: no osascript keystrokes, screencapture or window scraping — verify native apps in-process, web UIs with headless Puppeteer) are his alone, including through tools and agents you start.
4. **Never claim a check you didn't run in full.** Built means delivered (test the producer → reader round trip), done means live (verify on the restarted, running thing). Before handoff, check every commit — fixups too — the way the gates do. A test run is judged by its full set of failing names diffed against the baseline, never `| head`. When a theory dies the next move is a query, not another theory; a docstring is a claim, so run the path; label your own arithmetic as derived. Tests state an invariant with an injected clock and isolated config, never the real clock or machine.
5. **Make the tool refuse; don't rely on discipline.** Tools assume concurrent sessions and decline at the moment of the mistake — non-zero exit, a named, rare escape hatch. A bug class is fixed by a tool that refuses, never by documentation (the `verdict-key-guard` hook, the published-branch ward, `patch-land`).
6. **The smallest honest diff.** Add behavior through a thin seam (a new job, registry entry or query fn) and leave working code byte-identical to main; refactor only on a concrete problem (a second caller, untestable code, a growing branch), never for purity; a migration or infra branch changes no runtime behavior. Prefer explicit near-duplicates over a factory or a one-caller parameter, and K linear functions behind a routing switch over a `Plan` union consumed downstream. Keep schemas, types and helpers beside their one or two users until a third. New behavior in legacy-shaped code still ships its own seam; an extraction into a model fixes the contract (flagged, not ported) while a pure move stays byte-faithful. A rewrite measures first and proves exactness with a re-runnable differential harness.
7. **Survey what exists before writing anything new**: open one or two siblings and adopt their idioms (`Deps<>`, `fake<Entity>`, assert helpers — add a missing `fake<Entity>` to `testing/prisma/`); grep for callers of the primitives a helper composes; before a forest or a re-architecture, grep branches and the forest roster under the topic's synonyms, not your own vocabulary.
8. **Branch shape follows the reviewer and prod safety**, not node count or layer (mechanics: forests topic file). Any topo-legal merge prefix is a safe prod state; a design-feedback round on one screen is one branch even across layers.
9. **Tool UI is quiet.** One fact said once, one status signal per level, buttons for the top few motions only (check stack-usage) — a new capability routes into an existing slot or ⋯, and a new visible peer retires one. No mode pickers, no "— do X once Y" tails. Native macOS surfaces use template SF symbols, never emoji. Mutating actions live only on the surface that owns them (GitHub-page tooling shows state and links to canopy).
10. **Customer data never reaches an unsandboxed reader.** An agent CLI used as a model backend gets web search and every tool disabled — verified on a probe prompt — before it sees customer data.

# Just do both

**If a project has two things to do and both are yours to do, do them — don't make me pick the order.** Independent work has no order to get wrong; sequencing is your call. Do one, do the next, say in a line what you did.

**A "not built: X, Y" line at the end of a turn is a smell** — build them, or name the one blocker. **Only ask when my answer changes what gets built** — a design direction, a data model, a destructive or outward-facing step, a genuine ambiguity in the request. Never ask which of two independent things goes first, whether to do the obvious next increment, permission to keep going, or to re-confirm something I already said: pick the sensible option, state it, keep moving. If a real fork *is* hiding under the fake one, ask **that** — the upstream unknown both paths share, not the ordering. (2026-07-16: asked "which order?" about two freshly-independent siblings when the only real question was the data gap under both.)

**Report in plain language**: every update opens with the original ask, then what changes for Phil, then whether he must act — no labels coined mid-session; roll reviewer findings into a count plus the one worth knowing. Explain a mechanism in code order, tie each piece to the failure it prevents, gloss the mechanism words inline, and name the honest residual caveat. **An impossible result is a lead**: chase it to the root unasked — fix it in your lane, or hand the owner the mechanism and a repro — and say so in a line. A new design stands alone: lift a concrete rule from an old one, never its lineage.

<!-- claude-only -->
# Skills

**"Spec X", "design Y", "write up a plan", "whiteboard it" mean *produce a spec*** — inline in chat or a plain markdown file — not launch a tool. Same restraint for any heavyweight skill: pick the lightest action that fits, and let the user opt into the heavier tool.

# Your words for where things go

| Phil says | Means | How |
|---|---|---|
| "via message", "message me", "send me" | a note in Show's **Inbox** (⌘4) | `show-note "<title>" "<markdown>"` — every branch or forest in it a `[name](canopy://v2/b/<repo>/<branch>)` link |
| "show me", "put it in show" | a **deck** in Show, brought forward | `show --focus <deck.json>` (show skill) |
| "in the viewer", "in canopy" | the **canopy page** for that branch or forest | `canopy /v2/b/<repo>/<branch>` (or `/v2/p/<repo>/<project>`) |
| "open in web", "in the browser" | hand the URL to the default browser | `open <url-or-path>` — never drive a browser |

Combined, the words stack: "show me in the viewer, via message" = an Inbox note deeplinking the canopy page. **The Claude browser extension is NOT connected** — `mcp__claude-in-chrome__*` tools load but fail; browser automation or visual checks of a running app use Puppeteer (a small node script: headless Chromium, navigate, screenshot, assert on the DOM).
<!-- /claude-only -->

# Topic files

@~/.dotfiles/claude/dotfiles.md
@~/.dotfiles/claude/forests.md
@~/.dotfiles/claude/loops.md
@~/.dotfiles/claude/style.md
