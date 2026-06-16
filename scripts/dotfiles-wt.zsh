# dotfiles-wt.zsh — per-session isolation for ~/.dotfiles.
#
# Concurrent Claude sessions share one ~/.dotfiles working tree, so a `git add`
# in one session can sweep another's uncommitted edits into its commit (and
# same-file edits race). This gives each session its OWN worktree on a dot/<slug>
# branch — uncommitted state is fully isolated, collisions become impossible.
#
# Flow:
#   dotwt <slug>   create (or reuse) ~/.dotfiles-wt/<slug> on dot/<slug>, cd into it.
#                  Do ALL your dotfiles edits + commits here.
#   dotland        publish the worktree's branch to the live tree (~/.dotfiles):
#                  rebase onto current main, then fast-forward-merge into it.
#                  Disjoint WIP in ~/.dotfiles is left untouched — it only refuses
#                  if a FILE you're landing is itself dirty there. (A push-to-main
#                  with updateInstead was tried first but refuses on ANY dirty file,
#                  and the live tree is ~always dirty, so it never landed.)
#   dotpush        dotland, then push the live main to origin (backup/share).
#   dotrm          remove the current worktree when you're done (--branch also deletes it).
#
# Changes only go live on `dotland`; afterwards `source ~/.zshrc` / restart the
# viewer to pick them up. To TEST before landing, run scripts straight from the
# worktree path (e.g. launch the viewer from inside ~/.dotfiles-wt/<slug>).

DOTROOT="$HOME/.dotfiles"
DOTWT_DIR="$HOME/.dotfiles-wt"

dotwt() {
  emulate -L zsh
  local slug="${1:-}"
  [[ -n "$slug" ]] || { print -u2 "usage: dotwt <slug>"; return 2; }
  local wt="$DOTWT_DIR/$slug" br="dot/$slug"
  if [[ -d "$wt" ]]; then cd "$wt" && print "↪ reusing $wt ($br)"; return; fi
  if git -C "$DOTROOT" show-ref --verify --quiet "refs/heads/$br"; then
    git -C "$DOTROOT" worktree add "$wt" "$br" || return    # branch exists → re-attach
  else
    git -C "$DOTROOT" worktree add -b "$br" "$wt" main || return
  fi
  cd "$wt" && print "✦ dotfiles worktree: $wt on $br — edit/commit here, then \`dotland\`"
}

dotland() {
  emulate -L zsh
  local br; br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [[ "$br" == dot/* ]] || { print -u2 "dotland: run from a dot/* worktree (try \`dotwt <slug>\`)"; return 1; }
  [[ -z "$(git status --porcelain)" ]] || { print -u2 "dotland: commit your changes first (worktree is dirty)"; return 1; }
  local i out
  for i in 1 2 3 4 5; do
    git rebase main || { print -u2 "dotland: rebase onto main hit conflicts — resolve, then \`dotland\` again"; return 1; }
    # ff-merge into the live tree. Unlike push-to-checkout, this preserves disjoint
    # WIP in ~/.dotfiles and only refuses if a file you're landing is dirty there.
    out="$(git -C "$DOTROOT" merge --ff-only "$br" 2>&1)" && {
      print "✓ landed $br → main (live in ~/.dotfiles)"
      print "  pick it up: \`source ~/.zshrc\` / restart the viewer"
      return 0
    }
    if print -r -- "$out" | grep -qi 'overwritten by merge\|local changes'; then
      print -u2 "dotland: a file you're landing is dirty in ~/.dotfiles — commit/stash it there, then \`dotland\`:"
      print -ru2 -- "$out"; return 1
    fi
    print -r -- "$out" | grep -qi 'fast-forward' || { print -ru2 -- "$out"; return 1; }
    # else: main moved under us → loop rebases onto the new main and retries the merge
  done
  print -u2 "dotland: main kept moving after 5 tries — just run \`dotland\` again"; return 1
}

dotpush() { emulate -L zsh; dotland && git -C "$DOTROOT" push origin main; }

dotrm() {
  emulate -L zsh
  local br wt; br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"; wt="$(git rev-parse --show-toplevel 2>/dev/null)"
  [[ "$br" == dot/* && "$wt" == "$DOTWT_DIR/"* ]] || { print -u2 "dotrm: run from inside the dot/* worktree you want to remove"; return 1; }
  cd "$DOTROOT" && git worktree remove "$wt" && print "✓ removed $wt"
  [[ "${1:-}" == "--branch" ]] && git branch -D "$br" && print "✓ deleted $br"
}
