# Working in ~/.dotfiles

Rules first; mechanics below.

- **Never `zsource` / `git add -A` here.** Phil's `zsource` alias (`git add -A && git commit && git push && source ~/.zshrc`) is his to run, not Claude's: he often has concurrent in-progress dotfiles work, and `-A` sweeps his uncommitted WIP into your commit (it once bundled his ledger scripts into an unrelated `.zshrc` commit). Instead: run `git status` as its own step, then stage **explicit paths** (`git add .zshrc`), commit, push.
- **Pathspec commits cannot UNTRACK — delete from disk first.** `git commit -- X` re-reads X from the working tree, silently discarding a staged `git rm --cached X` and re-committing the bytes with a success exit code (98f9041 "untrack bytecode" did exactly this; all 23 .pyc stayed tracked). The safe form records an absence: `rm -rf X && git commit -m "…" -- X` (4f56495). Only for generated/regenerable files; a file that must survive on disk gets copied out, untrack-committed, copied back.
- **Never `git push --force` a branch another session may be live on** — that clobbers pushed work; leave a cosmetically-wrong commit message alone rather than rewrite shared history.
- **Reloads don't propagate.** `source ~/.zshrc` only affects your own subshell — tell Phil to source it in his terminal to pick up the change.
- **Never put scripts in ~/bin.** Everything lives in `~/.dotfiles/` so it's version controlled and nothing is lost if the computer dies: shell functions in `.zshrc` (or dedicated files sourced from it), standalone scripts in `~/.dotfiles/scripts/`.

## Concurrent sessions: claim a lane (`own` + `OWNERS`)

When multiple Claude sessions work this repo in parallel, each takes ONE lane (viewer / forest / stack / docs — see `~/.dotfiles/OWNERS`). At the start of dotfiles work run `own claim <your-lane>`; before editing any file run `own who <path>` — if it's YOUR lane, edit directly; if it's another lane (especially one flagged ⚠ ACTIVE), use the patch protocol below. Explicit lanes keep two sessions out of the same file.

## Editing a live file → author via patch, never direct

A file is "live" if it's dirty in `git status`, has a recent mtime, or changed between your Read and Edit. Writing it directly races/clobbers the other session. Instead:

1. **Author in a throwaway worktree at HEAD** — `git worktree add --detach /tmp/wt HEAD`, edit there (clean surface, zero collision).
2. **Capture a patch artifact** — `git -C /tmp/wt diff > ~/.dotfiles/patches/<name>.patch` (durable, reviewable, timing-independent, hand-off-able).
3. **Land with `git apply --3way`** — merges non-overlapping hunks, leaves conflict markers on overlap, *never* silent-clobbers. `git apply --check` tests it read-only first.

Apply when the file goes quiet, or hand the `.patch` to the session that owns the file. This is the standard for any contested file — it turns "two hands on one file" into a clean merge-or-conflict.

## Messaging another session: `claude-say <who> "<note>"` — SEND, don't draft

The tool submits by default (types into the target pane and presses Enter); that's the right default for session-to-session notes (fold-in heads-ups, lane handoffs) — a drafted note in an unattended pane is silently lost. Never pass `--draft` for these. `--draft` exists only for text a human must finish before sending (e.g. the viewer's ✦ seeded prompt stubs). The tool already guards the risky cases itself: it refuses non-Claude panes and auto-downgrades to draft if the target composer already holds text.
