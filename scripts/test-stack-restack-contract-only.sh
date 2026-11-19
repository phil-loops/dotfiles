#!/usr/bin/env bash
. "$(dirname "$0")/testenv.sh"   # git here ignores the machine's config
# test-stack-restack-contract-only.sh — --contract-only drops the members that landed (a merged PR
# whose head holds the tip) with nothing live on them, and moves nothing: a landed parent under an
# unmerged child stays, a landed branch GitHub doesn't call merged stays, a held one stays.
set -uo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTACK="$SCRIPTS_DIR/stack-restack"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/restack-contract.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1: $2"; }
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
exists() { git rev-parse -q --verify "refs/heads/$1" >/dev/null && echo yes || echo no; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE

git init -q --bare "$ROOT/origin.git"
git init -q -b main "$ROOT/repo"; cd "$ROOT/repo"
git remote add origin "$ROOT/origin.git"
echo base > README; git add README; git commit -qm base; git push -q origin main
mk() { git checkout -q -b "$1" "$2"; echo "$1" > "$1.txt"; git add "$1.txt"; git commit -qm "$1"
       git config "branch.$1.stack-parent" "$2"; git config "branch.$1.stack-project" proj; git config --add stack-project.proj.branch "$1"; }
# a: landed leaf · b: landed, c (unmerged) on it · d → e: both landed (no head sha: the classify
# fallback) · f: landed, no merged PR · g: landed, held · h: landed, main edited its file since ·
# i: landed, then a local commit on top · j: merged PR, no commits of its own · k: cut a minute ago
# l: cut a minute ago under a name whose old PR merged (that PR's head is unrelated history)
mk a main; mk b main; mk c b; mk d main; mk e d; mk f main; mk g main; mk h main; mk i main
I0=$(git rev-parse i); echo more >> i.txt; git commit -qam "i after merge"
git checkout -q -b old-l main; echo old > old-l.txt; git add old-l.txt; git commit -qm "old l"; L0=$(git rev-parse old-l)
git checkout -q main; git branch -q -D old-l
for x in j k; do git checkout -q -b "$x" main; git config "branch.$x.stack-parent" main; git config --add stack-project.proj.branch "$x"; done
git checkout -q main
for x in a b d e f g h i; do echo "$x" > "$x.txt"; git add "$x.txt"; git commit -qm "squash $x"; done   # the squash-merges
echo later >> h.txt; git commit -qam "main moves on over h"
git push -q origin main
git checkout -q -b l origin/main; git config branch.l.stack-parent main; git config --add stack-project.proj.branch l; git checkout -q main
C0=$(git rev-parse c)
heads() { for x in "$@"; do case $x in d|e) echo "$x -" ;; i) echo "i $I0" ;; l) echo "l $L0" ;; *) echo "$x $(git rev-parse "$x")" ;; esac; done; }

out=$(STACK_RESTACK_MERGED_HEADS="$(heads a b d e g h i j l)" STACK_RESTACK_OPEN_PR_HEADS=" " \
      "$RESTACK" proj --contract-only --no-claude --hold=g 2>&1); rc=$?
assert_eq "exits clean (rc)" 0 "$rc"
assert_eq "a (landed leaf) is gone" no "$(exists a)"
assert_eq "d (landed, landed child) is gone" no "$(exists d)"
assert_eq "e (landed leaf on d) is gone" no "$(exists e)"
assert_eq "h (main touched its file since) is gone" no "$(exists h)"
assert_eq "j (merged, no commits of its own) is gone" no "$(exists j)"
assert_eq "b stays under its live child" yes "$(exists b)"
assert_eq "c didn't move" "$C0" "$(git rev-parse c)"
assert_eq "c still sits on b" b "$(git config branch.c.stack-parent)"
assert_eq "f stays without a merged PR" yes "$(exists f)"
assert_eq "g stays while held" yes "$(exists g)"
assert_eq "i stays with a commit past its merged head" yes "$(exists i)"
assert_eq "k (no PR, no commits) stays" yes "$(exists k)"
assert_eq "l (a new branch under a merged PR's old name) stays" yes "$(exists l)"
assert_eq "the registry keeps the survivors" "b c f g i k l" "$(git config --get-all stack-project.proj.branch | sort | xargs)"

# the rest lands: the forest ships and its keys go with it
git checkout -q main; for x in c i; do git checkout -q "$x" -- "$x.txt"; git commit -qm "squash $x"; done; git push -q origin main
out=$(STACK_RESTACK_MERGED_HEADS="$(heads b c f g k; echo "l $(git rev-parse l)"; echo "i $(git rev-parse i)")" STACK_RESTACK_OPEN_PR_HEADS=" " \
      "$RESTACK" proj --contract-only --no-claude 2>&1); rc=$?
assert_eq "second pass exits clean (rc)" 0 "$rc"
assert_eq "the shipped forest leaves no project keys" "" "$(git config --get-regexp '^stack-project\.proj\.' || true)"
[[ $FAIL -gt 0 ]] && echo "$out"
echo "--- $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ))
