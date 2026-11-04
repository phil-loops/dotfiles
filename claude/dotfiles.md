# Working in ~/.dotfiles

Rules first; mechanics below.

- **No `zsource` / `git add -A`** (spine rule) — mechanics: `git status` as its own step, then stage **explicit paths** (`git add .zshrc`), commit, push. (Phil's `zsource` alias is his to run; `-A` once swept his in-progress ledger scripts into an unrelated commit.)
- **A pathspec commit only sees what git already tracks — land through `patch-land` even in your own lane.** `git commit -- X` re-reads tracked X from the working tree: it drops an untracked new file without a word (be58f2e: canopy's ReviewFlags.swift missed its commit, so 3c3f5ae doesn't build alone), and it can't untrack — a staged `git rm --cached X` is discarded and the bytes re-committed (98f9041). `patch-land` runs `git add` on every path the patch touches before its pathspec commit, so new files and deletions land in the same commit. Untracking a regenerable file still means `rm -rf X` first, so the commit records an absence (4f56495).
- **Reloads don't propagate.** `source ~/.zshrc` only affects your own subshell — tell Phil to source it in his terminal.
- **Script placement** (spine bans `~/bin`): shell functions in `.zshrc` (or dedicated files sourced from it), standalone scripts in `~/.dotfiles/scripts/`.

## Concurrent sessions: claim a lane (`own` + `OWNERS`)

Each concurrent session takes ONE lane (see `~/.dotfiles/OWNERS`). Start of dotfiles work: `own claim <your-lane>`; before editing any file: `own who <path>` — your lane → edit directly; another lane (especially ⚠ ACTIVE) → patch protocol below. Viewer/canopy/Show work also claims its tracker item first (`canopy-todo claim <id>`, refused while a live session owns it) — the tracker is the one list of who is building what. Show builds from its own copy (`~/.cache/show/src`) with canopy pinned to HEAD, so another lane's work reaches it only by commit.

## Editing a live file → author via patch, never direct

A file is "live" if it's dirty in `git status`, has a recent mtime, or changed between your Read and Edit. Writing it directly races/clobbers the other session. Instead:

1. **Author in a throwaway worktree at HEAD** — `git worktree add --detach /tmp/wt HEAD`, edit there.
2. **Capture a patch artifact** — `git -C /tmp/wt add -A && git -C /tmp/wt diff --cached > ~/.dotfiles/patches/<name>.patch` (`add -A` is safe in a throwaway worktree, and a plain `diff` would leave new files out).
3. **Land with `patch-land <patch> -m "<subject>"`** — `git apply --3way`, commits exactly the paths it touches, deletes the patch; refuses if those paths are dirty, and a conflict leaves tree and patch untouched.

Land when the file goes quiet, or hand the `.patch` to the session that owns the file. A patch left in `patches/` means *not landed yet* — `patch-land --sweep` says where each stands, `--prune` retires the ones already in.

## Messaging between sessions

`claude-say <who> "<note>"` sends to another Claude tmux session by default. Use `--draft` only for text a human must finish; the helper refuses non-Claude panes and leaves a draft when the target composer already holds text.

For Codex replies, use `/codex-reply` or `~/.dotfiles/scripts/codex-pane-say`: Phil runs Codex in the CLI, and the helper submits a signed note into the one tmux pane titled for the chat, refusing if its composer holds text. Phil authorized attributed Opus research replies to the chat titled **Review override cases**; tests go only to a throwaway Codex pane Phil names. (The GUI IPC bridge `codex-say` was retired 2026-10-22 after a desktop update broke its build pin.)
