# stack-config-lib.zsh — SOURCE this, don't run it. The one place a zsh script writes per-branch
# stack config, and the mirror of srv/stackcfg.py on the Python side.
#
# Why: the namespace migration moves `stack-branch.<b>.<key>` (legacy) → `branch.<b>.stack-<key>`
# (target, so git GCs it when the branch is deleted and carries it on rename). Phase 2 was
# written as "sweep every key and flip every writer in one window", which across the tree's write
# sites — in files several sessions hold — has no good moment. Dual-writing removes the window:
# writers emit BOTH spellings, readers already prefer the target, and the sweep then becomes
# idempotent and runnable any time.
#
# The failure mode this exists to prevent: after a sweep, a writer still emitting only the legacy
# spelling is SILENTLY SHADOWED, because readers take the target. A re-parent would report success
# and do nothing. Route writes through here and dropping the legacy spelling later is one edit.
#
#   stack_cfg_set   <branch> <key> <value>
#   stack_cfg_add   <branch> <key> <value>          # multivar
#   stack_cfg_unset <branch> <key> [value-pattern]
#   stack_cfg_drop_section <branch>                 # every stack key for the branch

stack_cfg_set() {
  git config "branch.$1.stack-$2" "$3"
  git config "stack-branch.$1.$2" "$3"
}

stack_cfg_add() {
  git config --add "branch.$1.stack-$2" "$3"
  git config --add "stack-branch.$1.$2" "$3"
}

stack_cfg_unset() {
  # git exits 5 for "was not set", which is not a failure here — and under `set -e` it would
  # abort the caller, so both arms swallow it.
  if [[ -n "${3:-}" ]]; then
    git config --unset "branch.$1.stack-$2" "$3" 2>/dev/null || true
    git config --unset "stack-branch.$1.$2" "$3" 2>/dev/null || true
  else
    git config --unset "branch.$1.stack-$2" 2>/dev/null || true
    git config --unset "stack-branch.$1.$2" 2>/dev/null || true
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
  git config --remove-section "stack-branch.$1" 2>/dev/null || true
}
