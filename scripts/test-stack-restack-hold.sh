#!/usr/bin/env bash
# test-stack-restack-hold.sh — a forest with two roots: --hold=<root> leaves that root and its
# child where they are while the other root moves onto fresh main (focus sync holds a published
# root instead of skipping the whole forest).
set -uo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTACK="$SCRIPTS_DIR/stack-restack"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/restack-hold.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1: $2"; }
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE

git init -q --bare "$ROOT/origin.git"
git init -q -b main "$ROOT/repo"; cd "$ROOT/repo"
git remote add origin "$ROOT/origin.git"
echo base > f; git add f; git commit -qm base; git push -q origin main
mk() { git checkout -q -b "$1" "$2"; echo "$1" > "$1.txt"; git add "$1.txt"; git commit -qm "$1"
       git config "branch.$1.stack-parent" "$2"; git config "branch.$1.stack-project" proj; git config --add stack-project.proj.branch "$1"; }
mk a main; mk b main; mk c b
git push -q origin b   # b is published: its subtree must not move
git checkout -q main; echo m1 > m1; git add m1; git commit -qm m1; git push -q origin main
B0=$(git rev-parse b); C0=$(git rev-parse c)

plan=$("$RESTACK" proj --plan --hold=b 2>&1)
echo "$plan" | grep -q '^  b .*HELD' && ok "plan marks the held root" || bad "plan marks the held root" "$plan"
echo "$plan" | grep -q '^  c .*HELD' && ok "plan marks the held root's child" || bad "plan marks the held root's child" "$plan"
echo "$plan" | grep '^  a ' | grep -qv HELD && ok "plan leaves the other root free" || bad "plan leaves the other root free" "$plan"

out=$("$RESTACK" proj --no-claude --no-classify --hold=b 2>&1); rc=$?
assert_eq "the walk exits clean (rc)" 0 "$rc"
[[ "$(git merge-base --is-ancestor origin/main a && echo yes)" == yes ]] && ok "a moved onto fresh main" || bad "a moved onto fresh main" "$out"
assert_eq "b stayed where it was" "$B0" "$(git rev-parse b)"
assert_eq "c stayed on b" "$C0" "$(git rev-parse c)"
echo "--- $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ))
