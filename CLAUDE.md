# Dotfiles

When updating dotfiles (scripts, zshrc, CLAUDE.md, etc), use `zsource` to commit and reload:
```
cd ~/.dotfiles && git add -A && git commit -m 'Update dotfiles' && git push && cd - && source ~/.zshrc
```

# Git Branch Stacks

**IMPORTANT:** Before suggesting `git rebase`, `git push`, or creating PRs, first check if the repo uses stacks:
```
test -f .stack && echo "STACKED REPO - use loops stack commands"
```

If a `.stack` file exists, ALWAYS use `loops stack` commands instead of raw git:

| Instead of... | Use... |
|---------------|--------|
| `git rebase` | `loops stack update` |
| `git push` | `loops stack push-all` |
| `gh pr create` | `loops stack pr` |
| `git checkout <ancestor>` | `loops stack edit <branch>` |

**Navigation:**
- `loops stack list` - show branch tree
- `loops stack parent` - print parent branch
- `loops stack step [--back]` - move to next/prev branch in stack
- `loops stack last` - switch to deepest branch in stack

**Stack operations:**
- `loops stack add <parent>` - track current branch as child of parent
- `loops stack check` - dry-run conflict detection (run before update)
- `loops stack update` - rebase current branch + descendants onto their parents
- `loops stack update --all` - rebase entire tree
- `loops stack remove [branch]` - untrack a branch

**Git/GitHub:**
- `loops stack pr` - push and create PR targeting parent branch
- `loops stack push-all` - push all tracked branches

**Editing ancestor branches:**
- `loops stack edit <branch>` - stash changes, checkout branch, remember where to return
- `loops stack return` - update descendants, return to original branch, restore stash
- `loops stack fixup <branch>` - apply staged changes to ancestor branch, update stack back to current

Run `loops stack` to see full help.

# Git Commits
Never add Co-Authored-By lines. Commits are mine alone.
