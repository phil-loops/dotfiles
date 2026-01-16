# Dotfiles

When updating dotfiles (scripts, zshrc, CLAUDE.md, etc), use `zsource` to commit and reload:
```
cd ~/.dotfiles && git add -A && git commit -m 'Update dotfiles' && git push && cd - && source ~/.zshrc
```

# Git Branch Stacks

When working with stacked/dependent branches, use the `stack` command instead of raw git commands:

- `stack add <parent>` - track current branch as child of parent
- `stack list` - show branch tree
- `stack update` - rebase current branch + descendants onto their parents
- `stack update --all` - rebase entire tree
- `stack parent` - print parent branch
- `stack pr` - push and create PR targeting parent branch
- `stack push-all` - push all tracked branches

The stack is stored in `.stack` file in the repo root. Check if it exists before suggesting raw git rebase commands.
