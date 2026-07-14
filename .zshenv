# Sourced by EVERY zsh — interactive, login, and `zsh -c` alike. PATH lives here (not
# .zshrc) because the things that reach for these scripts often aren't interactive shells:
# `tmux new-window "cd … && hx …"` (stack-open) runs `zsh -c`, which skips .zshrc entirely,
# so a Helix launched that way inherited a PATH without ~/.dotfiles/scripts and every
# binding that shells out (gh-open, hx-wc) died with command-not-found.
#
# Volta lives here for the same reason, and the stakes are higher than a missing command:
# `tsgo` is a volta shim, so a Helix launched without .zshrc can't resolve the language
# server in languages.toml — and helix does not error, it silently falls back to its
# built-in typescript-language-server (tsserver), which then indexes the repo in ~4 GB and
# spins a core forever. .zshrc keeps its own volta prepend so that in a login shell volta
# still outranks the homebrew node that .zprofile adds after us.
export VOLTA_HOME="$HOME/.volta"
typeset -U path
path=("$VOLTA_HOME/bin" "$HOME/.local/bin" "$HOME/.dotfiles/scripts" $path)
