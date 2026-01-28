# Dotfiles

When updating dotfiles (scripts, zshrc, CLAUDE.md, etc), use `zsource` to commit and reload:
```
cd ~/.dotfiles && git add -A && git commit -m 'Update dotfiles' && git push && cd - && source ~/.zshrc
```

## Script Placement
**Never put scripts in ~/bin.** Always place scripts in `~/.dotfiles/` so they're version controlled:
- Shell functions: `~/.dotfiles/.zshrc` or dedicated files sourced from it
- Standalone scripts: `~/.dotfiles/scripts/`

This ensures nothing is lost if the computer dies.

# Git Branch Stacks

Use **git-town** for stacked PRs.

**IMPORTANT: Always create branches with git-town, never `git checkout -b`:**
```bash
git town append <name>   # Create child of current branch
git town prepend <name>  # Create parent of current branch
```

If you accidentally created a branch with `git checkout -b`, fix it:
```bash
git town set-parent <parent-branch>
```

| Task | Command |
|------|---------|
| Create child branch | `git town append <name>` |
| Create parent branch | `git town prepend <name>` |
| Set parent (fix untracked) | `git town set-parent <branch>` |
| Sync all branches | `git town sync` |
| Create PR | `git town propose` |
| Navigate up/down | `git town up` / `git town down` |
| View stack | `git town branch` |
| Squash commits | `git town compress` |
| Move branch out of stack | `git town detach` |

Run `git town help` for full reference.

# Git Commits
Never add Co-Authored-By lines. Commits are mine alone.

# State and Acknowledgment Commands
Never automatically run commands that acknowledge, dismiss, or clear user state (like `whatchanged --ack`). The user must explicitly request these actions. Always ask before running any command that resets tracked state - don't assume that viewing something means the user wants to dismiss it.

# Loops Project Instructions

## Stack Webview

When asked to open the stack webview, use `loops stack webview` with the current stack prefix to filter branches. For example:

```
loops stack webview goals-v2
```

Derive the prefix from the current branch name (e.g., `goals-v2-23-goal-stats` → `goals-v2`).
