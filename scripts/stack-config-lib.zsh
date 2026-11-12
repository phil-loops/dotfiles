# stack-config-lib.zsh — SOURCE this, don't run it. The one place a zsh script writes per-branch
# stack config, `branch.<b>.stack-<key>` (git GCs it when the branch is deleted and carries it on
# rename), and the mirror of srv/stackcfg.py on the Python side.
#
# This is where the migration from `stack-branch.<b>.<key>` ended: writers went target-only on
# 2026-11-09, every repo was swept, and on 2026-11-12 the readers dropped their fallback arm.
#
#   stack_cfg_set   <branch> <key> <value>
#   stack_cfg_add   <branch> <key> <value>          # multivar
#   stack_cfg_unset <branch> <key> [value-pattern]
#   stack_cfg_drop_section <branch>                 # every stack key for the branch

stack_cfg_set() {
  git config "branch.$1.stack-$2" "$3"
}

stack_cfg_add() {
  git config --add "branch.$1.stack-$2" "$3"
}

stack_cfg_unset() {
  # git exits 5 for "was not set", which is not a failure here — and under `set -e` it would
  # abort the caller, so it is swallowed.
  if [[ -n "${3:-}" ]]; then
    git config --unset "branch.$1.stack-$2" "$3" 2>/dev/null || true
  else
    git config --unset "branch.$1.stack-$2" 2>/dev/null || true
  fi
}

stack_cfg_drop_section() {
  # The target side is unset KEY BY KEY on purpose: `--remove-section branch.<b>` would take
  # git's own branch.<b>.remote / .merge / .description with it. Dots in a branch name are
  # escaped so the regex can't over-match a sibling (wt-1.2 vs wt-1X2).
  local esc="${1//./\\.}" k
  git config --get-regexp "^branch\.${esc}\.stack-" 2>/dev/null | cut -d' ' -f1 | while read -r k; do
    [[ -n "$k" ]] && { git config --unset-all "$k" 2>/dev/null || true }
  done
}
