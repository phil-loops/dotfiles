#!/usr/bin/env bash
# test-stack-move-branch.sh — unpublished forest branches move in the object store, never by
# borrowing a checkout (2026-11-18: a restack rebased inside Phil's main checkout twice, and inside
# a stray checkout a gate run had re-created at a deleted path). stack-move-branch is the one mover;
# stack-restack replays and moves through it; stack-gates gates a detached copy. Temp repos only.
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/move-branch.XXXXXX")" && pwd -P)"
trap 'git -C "$ROOT/repo" worktree prune 2>/dev/null; rm -rf "$ROOT"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1: $2"; }
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export STACK_OPEN_DIR="$ROOT/scratch" STACK_RESTACK_OPEN_PR_HEADS=" "
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE

git init -q --bare "$ROOT/origin.git"
git init -q -b main "$ROOT/repo"; cd "$ROOT/repo"
git remote add origin "$ROOT/origin.git"
echo node_modules > .gitignore; echo base > f; git add .; git commit -qm base; git push -q origin main
mk() { git branch "$1" "$2"; git worktree add -q --detach "$ROOT/tmp-$1" "$1"
       echo "$1" > "$ROOT/tmp-$1/$1.txt"; git -C "$ROOT/tmp-$1" add "$1.txt"; git -C "$ROOT/tmp-$1" commit -qm "$1"
       git branch -f "$1" "$(git -C "$ROOT/tmp-$1" rev-parse HEAD)"; git worktree remove --force "$ROOT/tmp-$1"
       git config "branch.$1.stack-parent" "$2"; git config "branch.$1.stack-project" proj; git config --add stack-project.proj.branch "$1"; }

# ── the mover ──
mk free main
FREE0=$(git rev-parse free); NEXT=$(git commit-tree -p "$FREE0" -m next "$FREE0^{tree}")
"$S/stack-move-branch" free "$NEXT" "$(git rev-parse main)" 2>/dev/null; rc=$?
assert_eq "a stale expected tip is refused" "1 $FREE0" "$rc $(git rev-parse free)"
"$S/stack-move-branch" free "$NEXT" "$FREE0"
assert_eq "an unheld branch moves by compare-and-swap" "$NEXT" "$(git rev-parse free)"

mk held main
git worktree add -q "$ROOT/held" held
H0=$(git rev-parse held); H1=$(git -C "$ROOT/held" commit-tree -p "$H0" -m h1 "$(git rev-parse main^{tree})")
echo wip >> "$ROOT/held/held.txt"
out=$("$S/stack-move-branch" held "$H1" 2>&1); rc=$?
[[ $rc -eq 1 && "$out" == *"$ROOT/held"* && "$(git rev-parse held)" == "$H0" ]] \
  && ok "a dirty holder stops the move and is named" || bad "dirty holder" "rc=$rc $out"
git -C "$ROOT/held" checkout -q -- held.txt
"$S/stack-move-branch" held "$H1"
assert_eq "a clean holder moves with its branch" "$H1 $H1 refs/heads/held" \
  "$(git rev-parse held) $(git -C "$ROOT/held" rev-parse HEAD) $(git -C "$ROOT/held" symbolic-ref HEAD)"
[[ ! -e "$ROOT/held/held.txt" ]] && ok "…and its files follow" || bad "holder files" "held.txt still there"

mk gone main
git worktree add -q "$ROOT/gone" gone; rm -rf "$ROOT/gone"
G1=$(git commit-tree -p gone -m g1 "$(git rev-parse gone^{tree})")
"$S/stack-move-branch" gone "$G1"
[[ "$(git rev-parse gone)" == "$G1" && ! -e "$ROOT/gone" ]] \
  && ok "a deleted worktree holds nothing, and its path stays gone" || bad "deleted holder" "$(ls -d "$ROOT/gone" 2>&1)"

# ── stack-restack moves without a checkout ──
git worktree prune
mk r main; mk k r; mk lone r
git worktree add -q "$ROOT/k" k
git checkout -q main
git branch -f r "$(git commit-tree -p r -m r2 "$(git rev-parse r^{tree})")"
out=$("$S/stack-restack" proj --no-claude --no-classify 2>&1); rc=$?
assert_eq "the restack exits clean" 0 "$rc"
git merge-base --is-ancestor r k && git merge-base --is-ancestor r lone && ok "both children sit on the moved parent" || bad "children moved" "$out"
assert_eq "the checkout the restack ran in never left main" "refs/heads/main" "$(git symbolic-ref HEAD)"
[[ "$(git -C "$ROOT/k" reflog -1 --format=%gs HEAD)" != rebase* ]] \
  && ok "the clean holder was moved, not rebased in" || bad "holder rebased in" "$(git -C "$ROOT/k" reflog -3 --format=%gs HEAD)"
echo "$out" | grep -q "moved in the object store" && ok "the walk says it moved in the object store" || bad "walk output" "$out"

# ── gates gate a detached copy ──
git config --add stack-gates.cmd "clean::test ! -e wip.txt"
git worktree add -q "$ROOT/gated" free
echo wip > "$ROOT/gated/wip.txt"; git -C "$ROOT/gated" add wip.txt          # a holder's uncommitted bytes
out=$("$S/stack-gates" --branch free --full 2>/dev/null)
[[ "$out" == *'"name": "clean", "ok": true'* ]] && ok "gates check the branch's tip, not a holder's uncommitted bytes" || bad "gates in holder" "$out"
git -C "$ROOT/gated" reset -q --hard; git worktree add -q "$ROOT/vanished" lone 2>/dev/null; rm -rf "$ROOT/vanished"
"$S/stack-gates" --branch lone --full >/dev/null 2>&1
[[ ! -e "$ROOT/vanished" ]] && ok "a gate run never re-creates a deleted worktree" || bad "re-created" "$(ls -A "$ROOT/vanished")"
echo "--- $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ))
