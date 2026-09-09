# dotfiles

Phil's shell, editor, tmux, Claude Code, and loops-workflow config. Everything in `$HOME`
that matters is a symlink back into this repo, so the repo is the only thing to back up
and the only thing to set up. Nothing here is generated: edit the file in the repo, the
link means the app sees it.

## New machine

This section is written so an agent can be pointed at it and run the whole thing. Every
step is idempotent; re-running is safe.

### 1. Prerequisites

```bash
# Xcode CLT (git), then Homebrew (https://brew.sh), then:
brew install git gh jq fzf ripgrep fd tmux helix neovim starship go-task terminal-notifier python@3.13
brew install --cask orbstack hammerspoon swiftbar
curl https://get.volta.sh | bash && ~/.volta/bin/volta install node@22
curl -fsSL https://claude.ai/install.sh | bash        # Claude Code → ~/.local/bin/claude
```

- **OrbStack** is the only Docker engine the loops dev stack is tested against.
- **Volta** owns node; `~/.zshenv` puts it first on PATH deliberately (see the comment there).
- **Tailscale** (App Store) is needed for the database proxies, not for the shell.

### 2. Clone and link

```bash
git clone git@github.com:phil-loops/dotfiles.git ~/.dotfiles
~/.dotfiles/scripts/dotfiles-link            # creates every symlink; --check to audit, --dry-run to preview
exec zsh                                     # picks up .zshenv (PATH) and .zshrc
```

`dotfiles-link` holds the full list of what links where. A real file already at a link
path is moved to `<path>.pre-dotfiles`, never deleted.

### 3. Background agents

The launchd plists are linked by step 2 but not loaded. Load each once:

```bash
for p in ~/Library/LaunchAgents/com.philbrockman.*.plist; do launchctl bootstrap gui/$(id -u) "$p"; done
launchctl list | grep philbrockman           # every agent listed, status 0
```

### 4. Sign in

```bash
gh auth login                                # GitHub CLI; the viewer and prwatch use it
claude                                       # first run signs in to claude.ai
```

SwiftBar: point its plugin directory at `~/.dotfiles/swiftbar` in the SwiftBar
preferences. Hammerspoon: grant Accessibility when it asks.

### 5. The loops repo

```bash
git clone git@github.com:Loops-so/loops.git ~/coding/loops
dotfiles-link --loops ~/coding/loops         # pre-push, prepare-commit-msg, post-checkout, seed-gen hooks from hooks/
stack-install-precommit-hook ~/coding/loops  # oxfmt pre-commit hook
```

Both install into the common git dir, so every worktree of the repo is covered.
Secrets (`.env`, API keys) are never in this repo; get the loops `.env` from Phil.

### 6. Verify

```bash
dotfiles-link --check && dotfiles-link --loops ~/coding/loops --check   # all "ok", exit 0
own list                       # lanes resolve (reads OWNERS)
stack-review-port              # prints a port; the forest viewer is wired
hx --health typescript         # language server found via volta
```

## Layout

| Path | What |
|---|---|
| `.zshenv`, `.zshrc` | PATH lives in `.zshenv` so non-interactive shells get it; everything else in `.zshrc` |
| `scripts/` | every command; on PATH via `.zshenv`. `stack-*` is the forest tooling, `loops-*` the dev-stack tooling |
| `scripts/srv/`, `scripts/viewer-solid/` | the forest viewer: python server + Solid frontend (`stack web`) |
| `helix/`, `nvim/`, `tmux.conf`, `starship.toml` | editor and terminal config |
| `hooks/` | git hooks installed into the loops checkout |
| `launchd/` | background agents (CI mail watch, PR sweep, build notify) |
| `swiftbar/`, `hammerspoon/` | menu bar and hotkeys |
| `CLAUDE.md`, `claude/` | Claude Code instructions: hard rules in `CLAUDE.md`, mechanics in the `claude/` topic files |
| `.claude/` | Claude Code `settings.json`, agents, skills (linked to `~/.claude/`) |
| `OWNERS` | file lanes for concurrent Claude sessions; `own` reads it |
| `patches/` | patch artifacts from the concurrent-session edit protocol |
| `wiki/` | notes the viewer's Wiki tab serves |

## Working in this repo

Rules for editing here (lanes, patch protocol, no `git add -A`) are in `claude/dotfiles.md`.
Tests live beside the scripts they cover: `scripts/test-*.sh`, `scripts/stack-open-test`.
