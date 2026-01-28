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

Use **git-town** for stacked PRs. Key commands:

| Task | Command |
|------|---------|
| Create child branch | `git town append <name>` |
| Create parent branch | `git town prepend <name>` |
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
