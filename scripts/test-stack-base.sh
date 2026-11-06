#!/usr/bin/env bash
# test-stack-base.sh — throwaway-repo harness for scripts/stack-base.
# Asserts the recorded base wins only while it is still the branch's fork point: a branch
# rebased forward past its recorded base gets the new fork point (a stale base would let a
# squash swallow main's advance), while a parent rewritten backwards keeps the recorded one.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPTS_DIR/stack-base"
[[ -x "$BASE" ]] || { echo "missing: $BASE" >&2; exit 3; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/stack-base-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL  $1: $2"; }
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q -b main "$ROOT/repo"; cd "$ROOT/repo"
echo base > f; git add f; git commit -qm "base"
OLD_MAIN="$(git rev-parse main)"

# a: one commit on main, base recorded at its fork
git checkout -qb a
echo a1 > a1; git add a1; git commit -qm "a1"
git config branch.a.stack-parent main
git config branch.a.stack-base "$OLD_MAIN"

# T1: an unmoved branch keeps its recorded base
assert_eq "T1 recorded base wins while it is the fork point" "$OLD_MAIN" "$("$BASE" a)"

# T2: main advances and a is rebased onto it; the old base is still an ancestor of a,
# but no longer its fork point
git checkout -q main
for n in 1 2 3; do echo "m$n" > "m$n"; git add "m$n"; git commit -qm "m$n"; done
NEW_MAIN="$(git rev-parse main)"
git rebase -q main a
assert_eq "T2 a rebased forward gets the new fork point" "$NEW_MAIN" "$("$BASE" a)"
assert_eq "T2 the new base is persisted" "$NEW_MAIN" "$(git config branch.a.stack-base)"

# T3: main advances again but a is NOT rebased; its base stays put
git checkout -q main
echo m4 > m4; git add m4; git commit -qm "m4"
assert_eq "T3 main moving alone leaves the base" "$NEW_MAIN" "$("$BASE" a)"

# T4: b stacked on a; a is rewritten backwards (its tip dropped) — b's recorded base must
# survive, since the fork point with the rewritten parent is now older than b's real base
git checkout -q a
git checkout -qb b
echo b1 > b1; git add b1; git commit -qm "b1"
A_TIP="$(git rev-parse a)"
git config branch.b.stack-parent a
git config branch.b.stack-base "$A_TIP"
git branch -f a a~1
assert_eq "T4 a parent rewritten backwards keeps the recorded base" "$A_TIP" "$("$BASE" b)"

# T5: no recorded base derives the fork point
git config --unset branch.b.stack-base
assert_eq "T5 no record derives merge-base(parent, branch)" "$(git merge-base a b)" "$("$BASE" b)"

echo "--- $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
