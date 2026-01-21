# Dotfiles

When updating dotfiles (scripts, zshrc, CLAUDE.md, etc), use `zsource` to commit and reload:
```
cd ~/.dotfiles && git add -A && git commit -m 'Update dotfiles' && git push && cd - && source ~/.zshrc
```

# Git Branch Stacks

**IMPORTANT:** Before suggesting `git rebase`, `git push`, or creating PRs, first check if the repo uses stacks:
```
test -f .stack && echo "STACKED REPO - use stack commands"
```

If a `.stack` file exists, ALWAYS use `stack` commands instead of raw git:

| Instead of... | Use... |
|---------------|--------|
| `git rebase` | `stack update` |
| `git push` | `stack push-all` |
| `gh pr create` | `stack pr` |
| `git checkout <ancestor>` | `stack edit <branch>` |

**Available commands:**
- `stack add <parent>` - track current branch as child of parent
- `stack list` - show branch tree
- `stack check` - dry-run conflict detection (run before update)
- `stack update` - rebase current branch + descendants onto their parents
- `stack update --all` - rebase entire tree
- `stack parent` - print parent branch
- `stack pr` - push and create PR targeting parent branch
- `stack push-all` - push all tracked branches

**For editing ancestor branches:**
- `stack edit <branch>` - stash changes, checkout branch, remember where to return
- `stack return` - update descendants, return to original branch, restore stash
- `stack edit --abort` - cancel edit mode without changes
- `stack fixup <branch>` - apply staged changes to ancestor branch, update stack back to current

**Important:** Always use the shell alias via `/bin/zsh -ic 'stack ...'` instead of running the script directly.

# Git Commits
Never add Co-Authored-By lines. Commits are mine alone.
