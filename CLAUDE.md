# How this file is organized

Hard rules and behavioral defaults live here, always in view. Mechanics live in the imported topic files at the bottom. When adding guidance: an invariant goes under *Hard rules*, a procedure goes in the matching topic file, and a dated war story gets compressed to a one-line parenthetical (the full story belongs in memory, not here). **Every addition contracts**: fold the lesson into the existing rule that should have caught it and delete what that makes redundant — a new section is a last resort, net growth needs a reason, and guidance that only accretes dilutes every rule already there.

# Hard rules

Non-negotiable, in every repo, regardless of what a task seems to call for.

**Pushing & PRs**

- **Never push branches or open PRs — Phil handles both himself** (pushes to `origin` = `Loops-so/loops` via GH Desktop / the viewer; opens every PR manually). Claude's job ends at a prepped local branch + a drafted PR body. PR branches and PRs live on `origin` directly (origin-internal, not fork PRs); the `phil-loops` fork is only for bench/experimental branches (and is `stack-push.remote`), never the PR flow. Never let tooling open PRs — that's manual.
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

**If a project has two things to do and both are yours to do, do them — don't make me pick the order.**
Independent work has no order to get wrong: when neither blocks the other and each stands on its own,
sequencing is your call. Asking costs a round trip and buys nothing — and once you've split out a base
so its consumers are siblings, "which sibling first?" is a question you just engineered away. Do one,
do the next, say in a line what you did.

**Only ask when my answer changes what gets built** — a real fork with a wrong branch: a design
direction, a data model, a destructive or outward-facing step, a genuine ambiguity in the request.
**Never ask when my input doesn't move the needle downstream**: which of two independent things goes
first, whether to do the obvious next increment, permission to keep going, or re-confirming something
I already said. Pick the sensible option, state it, keep moving.

If a real fork *is* hiding under the fake one, ask **that** instead — the upstream unknown both paths
share, not the ordering. (Anti-pattern, 2026-07-16: after hoisting a shared primitive out so the map
badge and the spine became independent consumers, I was asked "which order?" — when the only thing
that mattered was the data gap sitting underneath both.)

# Skills

**The `design` skill (nvim whiteboard `:submit` loop) is opt-in only.** Phrases like "let's spec X", "design Y", "write up a plan", or "whiteboard it" do NOT mean launch it — they mean produce a spec. Default to writing the spec **inline** in chat (or a plain markdown file the user can read). Only start the design-doc loop when the user **explicitly** asks for that tool/flow. *Offer* it ("want to iterate on this in the design whiteboard?") rather than launching it. Same restraint for any heavyweight skill: pick the lightest action that fits, and let the user opt into the heavier tool.

# Browser / "open in web"

**The Claude browser extension is NOT installed/connected.** The `mcp__claude-in-chrome__*` tools *load* via ToolSearch but fail at runtime with "browser extension is not connected" — don't rely on them. **For browser automation or visual verification of a running app, use Puppeteer** (a headless-Chromium script — `npx puppeteer`, or a small node script that launches Chromium, navigates, screenshots, and asserts on the DOM). When the user says **"open in web"** (or "open in the browser"), they mean run the commandline **`open <url-or-path>`** to hand it off to the default browser — not drive a browser via Claude. (Distinct from `stack web`, which is the forest viewer server the user reviews on himself.)

# Topic files

@~/.dotfiles/claude/dotfiles.md
@~/.dotfiles/claude/forests.md
@~/.dotfiles/claude/loops.md
@~/.dotfiles/claude/style.md
