---
name: prwatch
description: Check, watch, or diagnose CI status for the user's GitHub PRs and Actions runs. Use when they ask "are my PRs passing?", "what's failing on PR/run X?", "watch this run/PR", paste a github.com pull or actions/runs URL and want its status, or ask to monitor CI. Wraps the `prwatch` CLI + `gh`; your edge over the bare CLI is reading the failing logs and explaining (and offering to fix) the actual error.
---

# prwatch — monitor & diagnose PR / CI

The user has a `prwatch` script (`~/.dotfiles/scripts/prwatch`) and `gh`. Use them to answer
CI/PR questions. **Your value over the bare CLI: when something is red, pull the logs and
explain the real failure, then offer a fix** — the CLI only says "✗ failing".

These commands are all read-only. `gh pr checks` / `gh run view|watch` never re-run or trigger CI.

## 1. Status at a glance — non-blocking, this is the default
- **All their PRs:** `prwatch --list` → open PRs sorted ✗ failing → ● running → ✓ passing → ○ no-checks
  (scans the fork + team repo). Lead with the failing/running ones; don't dump 40 "no checks" fork PRs.
- **One PR (number or `…/pull/<n>` URL):** `gh pr checks <num> --repo <repo>` for the current rollup.
- **One Actions run (`…/actions/runs/<id>` URL):** `gh run view <id> --repo <repo>`.

Parse `<owner>/<repo>` and the number/run-id straight from any github.com URL the user pastes.

> NEVER use `--watch` inside a normal (foreground) tool call — it blocks until the run finishes.

## 2. Diagnose a failure — the main reason to use Claude here
When a PR/run is red:
1. Find the failing run — from a PR, `gh pr checks <num> --repo <repo>` lists each check's run URL;
   or `gh run list --repo <repo> --branch <headRef> -L 1`.
2. Pull the failing logs: `gh run view <run-id> --repo <repo> --log-failed`.
3. Summarize the **actual** error — the failing step + the handful of relevant lines. Don't paste the
   whole log. Then offer to fix it (and, if in the repo, actually fix it).

## 3. Watch until it finishes — only when they say "watch" / "tell me when it's done"
Don't block on `--watch`. Run the watch in the **background** so the harness re-invokes you on
completion, then report — and if it failed, immediately diagnose (step 2):
- run: `gh run watch <run-id> --repo <repo> --exit-status`  (run_in_background)
- PR:  `gh pr checks <num> --repo <repo> --watch`           (run_in_background)

## Repos & passive monitoring
- Default repos: `phil-loops/loops` (the fork — **no CI**) and `Loops-so/loops` (where CI actually runs).
  Override via `git config stack.pr-repos "owner/repo …"`.
- A launchd agent (`prwatch --sweep`, label `com.phil.prwatch-sweep`) already pings the user when an
  open PR goes red. For ongoing/passive monitoring, point them at that — don't sit in a foreground watch.

## prwatch CLI reference (for the user's own terminal)
`prwatch` (fzf-pick + watch) · `prwatch <n>` · `prwatch <github-url>` (PR or run) · `prwatch -l` (list) ·
`prwatch --sweep` (the launchd poller). Notifications go via terminal-notifier (clicking opens the PR) —
not relevant inside a Claude session; just report status in chat.
