#!/usr/bin/env bash
# test-stack-reword.sh — throwaway-repo harness for scripts/stack-reword.
# Builds main → a (3 commits) → b (1 commit) with forest config and a bare origin,
# then asserts: trees never change, the target message changes, descendants reseat,
# frozen bases re-point, and pushed / below-base / unchanged cases refuse or no-op.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REWORD="$SCRIPTS_DIR/stack-reword"
[[ -x "$REWORD" ]] || { echo "missing: $REWORD" >&2; exit 3; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/stack-reword-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL  $1: $2"; }
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q -b main "$ROOT/origin.git" --bare
git init -q -b main "$ROOT/repo"; cd "$ROOT/repo"
git remote add origin "$ROOT/origin.git"
echo base > f; git add f; git commit -qm "base"; git push -q origin main
git checkout -qb a
for n in 1 2 3; do echo "a$n" > "a$n"; git add "a$n"; git commit -qm "a$n subject" -m "a$n body"; done
git config stack-branch.a.parent main
git checkout -qb b
echo b1 > b1; git add b1; git commit -qm "b1 subject"
git config stack-branch.b.parent a
git config stack-branch.b.base "$(git rev-parse a)"
git checkout -q a

A2="$(git rev-parse a~1)"; A_TREE="$(git rev-parse 'a^{tree}')"; B_TREE="$(git rev-parse 'b^{tree}')"
A2_TREE="$(git rev-parse "$A2^{tree}")"; OLD_A="$(git rev-parse a)"

# T1: reword a middle commit with -m, checked-out branch, child reseats
out="$("$REWORD" "$A2" -m "a2 new subject" -m "new body" 2>&1)"; rc=$?
assert_eq "T1 exit 0" 0 "$rc"
assert_eq "T1 a tree unchanged" "$A_TREE" "$(git rev-parse 'a^{tree}')"
assert_eq "T1 b tree unchanged" "$B_TREE" "$(git rev-parse 'b^{tree}')"
assert_eq "T1 a2 tree unchanged" "$A2_TREE" "$(git rev-parse 'a~1^{tree}')"
assert_eq "T1 new subject" "a2 new subject" "$(git log -1 --format=%s a~1)"
assert_eq "T1 new body" "new body" "$(git log -1 --format=%b a~1 | git stripspace)"
assert_eq "T1 a3 message kept" "a3 subject" "$(git log -1 --format=%s a)"
assert_eq "T1 b on new a tip" "$(git rev-parse a)" "$(git rev-parse b~1)"
assert_eq "T1 b base re-pointed" "$(git rev-parse a)" "$(git config stack-branch.b.base)"
assert_eq "T1 worktree clean" "" "$(git status --porcelain)"
assert_eq "T1 HEAD still a" "a" "$(git symbolic-ref --short HEAD)"
assert_eq "T1 author date kept" "$(git log -1 --format=%ad "$OLD_A")" "$(git log -1 --format=%ad a)"

# T2: editor mode pre-fills subject + body; editor rewrites the subject only
cat > "$ROOT/ed" <<'ED'
#!/usr/bin/env bash
grep -q '^a2 new subject$' "$1" && grep -q '^new body$' "$1" || { echo "prefill missing" >&2; exit 9; }
sed -i '' 's/^a2 new subject$/a2 edited/' "$1"
ED
chmod +x "$ROOT/ed"
GIT_EDITOR="$ROOT/ed" "$REWORD" a~1 >/dev/null 2>&1; rc=$?
assert_eq "T2 exit 0" 0 "$rc"
assert_eq "T2 subject edited" "a2 edited" "$(git log -1 --format=%s a~1)"
assert_eq "T2 body kept" "new body" "$(git log -1 --format=%b a~1 | git stripspace)"

# T3: unchanged message is a no-op
before="$(git rev-parse a)"
GIT_EDITOR=true "$REWORD" a~1 >/dev/null 2>&1; rc=$?
assert_eq "T3 exit 0" 0 "$rc"
assert_eq "T3 ref untouched" "$before" "$(git rev-parse a)"

# T4: commit at/below the base is refused and names the owner
out="$("$REWORD" main -m x 2>&1)"; rc=$?
assert_eq "T4 refused" 1 "$rc"
[[ "$out" == *"belongs to main"* ]] && ok "T4 names parent" || bad "T4 names parent" "$out"

# T5: pushed commit is refused
git push -q origin a
out="$("$REWORD" a~1 -m x 2>&1)"; rc=$?
assert_eq "T5 refused" 1 "$rc"
[[ "$out" == *"already pushed"* ]] && ok "T5 says pushed" || bad "T5 says pushed" "$out"

# T6: a pushed child means the target is pushed too — the first refusal covers it
git push -q origin b
git push -q origin --delete a
out="$("$REWORD" --branch a a~1 -m x 2>&1)"; rc=$?
assert_eq "T6 child pushed refused" 1 "$rc"
[[ "$out" == *"origin/b"* ]] && ok "T6 names the holder" || bad "T6 names the holder" "$out"
git push -q origin --delete b

# T7: --branch on a branch not checked out; a stale child (not on the parent's tip) is skipped
git checkout -q main
echo a4 > a4; git checkout -q a; git add a4; git commit -qm "a4 subject"; git checkout -q main
OLD_B="$(git rev-parse b)"
out="$("$REWORD" --branch a a -m "a4 renamed" 2>&1)"; rc=$?
assert_eq "T7 exit 0" 0 "$rc"
assert_eq "T7 reworded" "a4 renamed" "$(git log -1 --format=%s a)"
assert_eq "T7 stale child untouched" "$OLD_B" "$(git rev-parse b)"
[[ "$out" == *"b does not sit on a's tip"* ]] && ok "T7 warns" || bad "T7 warns" "$out"

echo; echo "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]]
