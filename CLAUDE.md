# How this file is organized

Hard rules and behavioral defaults live here, always in view. Mechanics live in the imported topic files at the bottom. When adding guidance: an invariant goes under *Hard rules*, a procedure goes in the matching topic file, and a dated war story gets compressed to a one-line parenthetical (the full story belongs in memory, not here). **Every addition contracts**: fold the lesson into the existing rule that should have caught it and delete what that makes redundant — a new section is a last resort, net growth needs a reason, and guidance that only accretes dilutes every rule already there.

# Hard rules

Non-negotiable, in every repo, regardless of what a task seems to call for.

**Pushing & PRs**

- **Never push branches or open PRs — Phil handles both himself**, and never let tooling do either. Claude's job ends at a prepped local branch + a drafted PR body — and when the branch is bound for a push (a new PR against main, or new commits onto an open PR), "prepped" includes sealed + server-recorded gates-green (`/push-ready`): run the gates unprompted, and any commit landing on a gated tip re-runs them. (Remote topology: loops topic file.)
- Committing locally is fine — make clean, self-contained commits.

**History**

- **Never amend commits** — always create new commits. PRs are squash-merged, so local history noise doesn't matter.
- **Never add Co-Authored-By lines.**
- **Never create merge commits** — forest history stays linear; fan-in lives in `requires` metadata + carried cherry-picks.
- **Never `git push --force` a branch another session may be live on** — leave a cosmetically-wrong commit message alone rather than rewrite shared history.

**Dotfiles**

- **Never `zsource` / `git add -A` in `~/.dotfiles`** — `-A` sweeps Phil's concurrent WIP into your commit. `git status` as its own step, then stage explicit paths (mechanics: dotfiles topic file).
- **Never put scripts in `~/bin`** — they go in `~/.dotfiles/` so they're version controlled.

**Forest viewer & gates**

- **Never curl-probe a mutating viewer endpoint with a real branch name** — `POST /checkout` yanks the main working tree off a live branch. Probe with a nonexistent branch (`__probe__`) or empty body and assert 400/404.
- **Never hand-write the `gates-green-tree` config key for a real branch** — that forges a green gates verdict without running the gates.

# Just do both

**If a project has two things to do and both are yours to do, do them — don't make me pick the order.** Independent work has no order to get wrong; sequencing is your call. Do one, do the next, say in a line what you did.

**Only ask when my answer changes what gets built** — a design direction, a data model, a destructive or outward-facing step, a genuine ambiguity in the request. Never ask which of two independent things goes first, whether to do the obvious next increment, permission to keep going, or to re-confirm something I already said: pick the sensible option, state it, keep moving. If a real fork *is* hiding under the fake one, ask **that** — the upstream unknown both paths share, not the ordering. (2026-07-16: asked "which order?" about two freshly-independent siblings when the only real question was the data gap under both.)

# Skills

**The `design` skill (nvim whiteboard `:submit` loop) is opt-in only.** "Spec X", "design Y", "write up a plan", "whiteboard it" mean *produce a spec* — inline in chat or a plain markdown file — not launch the tool; *offer* it, launch only on an explicit ask. Same restraint for any heavyweight skill: pick the lightest action that fits, and let the user opt into the heavier tool.

# Browser / "open in web"

**The Claude browser extension is NOT installed/connected** — the `mcp__claude-in-chrome__*` tools load via ToolSearch but fail at runtime; don't rely on them. **For browser automation or visual verification of a running app, use Puppeteer** (a small node script that launches headless Chromium, navigates, screenshots, asserts on the DOM). **"open in web" / "open in the browser" means run `open <url-or-path>`** — hand off to the default browser, don't drive one. (Distinct from `stack web`, the forest viewer Phil reviews on himself.)

# Topic files

@~/.dotfiles/claude/dotfiles.md
@~/.dotfiles/claude/forests.md
@~/.dotfiles/claude/loops.md
@~/.dotfiles/claude/style.md
