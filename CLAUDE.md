# Dotfiles

When updating dotfiles (scripts, zshrc, CLAUDE.md, etc), use `zsource` to commit and reload:
```
cd ~/.dotfiles && git add -A && git commit -m 'Update dotfiles' && git push && cd - && source ~/.zshrc
```

# Git Branch Stacks

Stacked PRs break large features into small, focused, reviewable changes (~150 LOC each).

**IMPORTANT:** Before using `git rebase`, `git push`, or `gh pr create`, check for stacks:
```
test -f .stack && echo "STACKED REPO" && loops stack
```

If a `.stack` file exists, use `loops stack` commands instead of raw git:

| Instead of... | Use... |
|---------------|--------|
| `git rebase` | `loops stack update` |
| `git push` | `loops stack push-all` |
| `gh pr create` | `loops stack pr` |
| `git checkout <ancestor>` | `loops stack edit <branch>` |

**Key concepts:**
- `loops stack info` - overview with size, drift, conflicts (use `-s`, `-d`, `-c` for details)
- `loops stack go <next|prev|last|root>` - navigate the stack
- `loops stack edit/return/fixup` - edit ancestor branches safely

Run `loops stack` for full command reference.

# Git Commits
Never add Co-Authored-By lines. Commits are mine alone.

# State and Acknowledgment Commands
Never automatically run commands that acknowledge, dismiss, or clear user state (like `whatchanged --ack`). The user must explicitly request these actions. Always ask before running any command that resets tracked state - don't assume that viewing something means the user wants to dismiss it.
