# Working in ~/.dotfiles

Rules first; mechanics below.

- **No `zsource` / `git add -A`** (spine rule) — mechanics: `git status` as its own step, then stage **explicit paths** (`git add .zshrc`), commit, push. (Phil's `zsource` alias is his to run; `-A` once swept his in-progress ledger scripts into an unrelated commit.)
- **Pathspec commits cannot UNTRACK — delete from disk first.** `git commit -- X` re-reads X from the working tree, silently discarding a staged `git rm --cached X` and re-committing the bytes with a success exit code (98f9041: all 23 .pyc stayed tracked). The safe form records an absence: `rm -rf X && git commit -m "…" -- X` (4f56495). Only for regenerable files; a file that must survive on disk gets copied out, untrack-committed, copied back.
- **Reloads don't propagate.** `source ~/.zshrc` only affects your own subshell — tell Phil to source it in his terminal.
- **Script placement** (spine bans `~/bin`): shell functions in `.zshrc` (or dedicated files sourced from it), standalone scripts in `~/.dotfiles/scripts/`.

## Concurrent sessions: claim a lane (`own` + `OWNERS`)

Each concurrent session takes ONE lane (see `~/.dotfiles/OWNERS`). Start of dotfiles work: `own claim <your-lane>`; before editing any file: `own who <path>` — your lane → edit directly; another lane (especially ⚠ ACTIVE) → patch protocol below.

## Editing a live file → author via patch, never direct

A file is "live" if it's dirty in `git status`, has a recent mtime, or changed between your Read and Edit. Writing it directly races/clobbers the other session. Instead:

1. **Author in a throwaway worktree at HEAD** — `git worktree add --detach /tmp/wt HEAD`, edit there.
2. **Capture a patch artifact** — `git -C /tmp/wt diff > ~/.dotfiles/patches/<name>.patch` (durable, reviewable, hand-off-able).
3. **Land with `git apply --3way`** — merges non-overlapping hunks, conflicts loudly on overlap, never silent-clobbers; `git apply --check` tests read-only first.

Apply when the file goes quiet, or hand the `.patch` to the session that owns the file. Standard for any contested file.

## Messaging another session: `claude-say <who> "<note>"` — SEND, don't draft

Submits by default (types into the target pane + Enter) — right for session-to-session notes; a drafted note in an unattended pane is silently lost. `--draft` is only for text a human must finish (e.g. the viewer's ✦ seeded prompt stubs). The tool guards the risky cases itself: refuses non-Claude panes, auto-downgrades to draft if the target composer holds text.
