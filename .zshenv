# Sourced by EVERY zsh — interactive, login, and `zsh -c` alike. PATH lives here (not
# .zshrc) because the things that reach for these scripts often aren't interactive shells:
# `tmux new-window "cd … && hx …"` (stack-open) runs `zsh -c`, which skips .zshrc entirely,
# so a Helix launched that way inherited a PATH without ~/.dotfiles/scripts and every
# binding that shells out (gh-open, hx-wc) died with command-not-found.
typeset -U path
path=("$HOME/.local/bin" "$HOME/.dotfiles/scripts" $path)
