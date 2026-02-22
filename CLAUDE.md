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

| Task                       | Command                         |
| -------------------------- | ------------------------------- |
| Create child branch        | `git town append <name>`        |
| Create parent branch       | `git town prepend <name>`       |
| Set parent (fix untracked) | `git town set-parent <branch>`  |
| Sync all branches          | `git town sync`                 |
| Create PR                  | `git town propose`              |
| Navigate up/down           | `git town up` / `git town down` |
| View stack                 | `git town branch`               |
| Squash commits             | `git town compress`             |
| Move branch out of stack   | `git town detach`               |

Run `git town help` for full reference.

# Git Changes

Never add Co-Authored-By lines. Never commit — the user will handle commits themselves.

Structure changes atomically — each branch/commit should be a single, self-contained change. When working on multi-part changes, decouple them into separate branches in the stack, ordering zero-dependency changes first.

# Git Pushing & PRs

**Never push to origin or open PRs.** The user will handle pushing and opening PRs themselves.

In the loops repo specifically:
- `origin` is `Loops-so/loops` — **never push here**
- `phil-loops` is `phil-loops/loops` — only use this remote if pushing is needed
