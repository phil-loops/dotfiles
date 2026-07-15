# PR review in Helix

Helix has no Diffview. `⌘⇧O` on a GitHub PR (via the gh-to-nvim extension) instead opens the PR
in a **gutter review mode**: every changed file is loaded as a buffer in a `review-hx` tmux window,
inside a throwaway worktree that's been `git reset --soft <merge-base>`. That makes the whole PR
read as "uncommitted," so Helix's **diff gutter lights up every change** and you walk it with motions.

Wired in `~/.dotfiles/scripts/stack-open` (`--review` path, `ensure_review_worktree`).

## The shortcuts

| Key | Does |
| --- | --- |
| `]g` / `[g` | next / previous **change** (git hunk) in the current file |
| `]G` / `[G` | last / first change in the file |
| `Space b` | **buffer picker** — jump between the PR's changed files |
| `Space f` | file picker (open a file the PR didn't touch, for context) |
| `gd` | go to definition · `gr` find references — read the change in context (warm LSP) |
| `Space d` | diagnostics — does the change introduce LSP errors |
| `Space s` | symbol picker for the current file |

The gutter marks in the left margin (`▍` add / modify / delete) are the review surface — no line
selected on GitHub means you land on the first changed file's first hunk; `]g` takes you through
the rest, `Space b` to the next file.

## Line-precise open

Click a line number on GitHub first, *then* `⌘⇧O` → lands on that exact file:line in the main
checkout (editable), not this review worktree.

## Safety / mechanics

- The review worktree (`/tmp/stack-study/<branch>__review`) is **separate** from your editable
  checkout — the soft-reset never touches your working tree.
- It carries **no commit-follow marker**: if you accidentally `:wc`/commit while reviewing, the
  commit strands on a detached HEAD (recover via `git reflog`) instead of force-moving the branch.
- Disposable: re-opening hard-refreshes it to the tip; idle ones are pruned after 3 days.
- Edits made in a review buffer are **discarded** on re-open — it's a read surface, not a workspace.
