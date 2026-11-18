#!/usr/bin/env bash
# test-stack-integrate.sh — throwaway-repo harness for scripts/stack-integrate.
# The forest from goal-flip-converter (2026-11-17): base `a` edits a file and later
# gets a fix elsewhere; `d` builds on a; `b` carries a's first commit (requires) and then
# deletes the file; `c` is an independent sibling. Replaying in merge order with
# patch-id skips must integrate them cleanly to exactly what landing leaves, and a
# genuine overlap must still fail, naming the member that doesn't apply.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTEGRATE="$SCRIPTS_DIR/stack-integrate"
export PATH="$SCRIPTS_DIR:$PATH"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/stack-integrate-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL  $1: $2"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q -b main "$ROOT/repo"; cd "$ROOT/repo"
printf 'one\ntwo\n' > shared; echo base > f; git add -A; git commit -qm base

git checkout -qb a
printf 'one\ntwo\nthree\n' > shared; git commit -qam "a: add three"
A1=$(git rev-parse HEAD)
echo fix > a-fix; git add a-fix; git commit -qm "a: fix elsewhere"

git checkout -qb d
echo d > d-file; git add d-file; git commit -qm "d: build on a"

git checkout -q main; git checkout -qb b
git cherry-pick "$A1" >/dev/null
git rm -q shared; git commit -qm "b: remove shared"

git checkout -q main; git checkout -qb c
echo c > c; git add c; git commit -qm "c: add c"
git checkout -q main

for m in a b c d; do git config --add stack-project.p.branch "$m"; git config branch.$m.stack-parent main; git config branch.$m.stack-project p; done
git config branch.d.stack-parent a
git config --add branch.b.stack-requires a


if out=$("$INTEGRATE" p 2>&1); then
  ok "a carried copy and its fixed original integrate cleanly"
  tree=$(git ls-tree --name-only refs/stack/p-integration | sort | tr '\n' ' ')
  [[ "$tree" == "a-fix c d-file f " ]] && ok "the result is what landing in order leaves: shared removed; a-fix, c and d-file added" \
    || bad "integration tree" "got [$tree]"
else
  bad "integrate" "$out"
fi

git checkout -q main; git checkout -qb x
echo x > f; git commit -qam "x: rewrite f"
git checkout -q main; git checkout -qb y
echo y > f; git commit -qam "y: rewrite f differently"
git checkout -q main
for m in x y; do git config --add stack-project.q.branch "$m"; git config branch.$m.stack-parent main; done
if out=$("$INTEGRATE" q 2>&1); then
  bad "a real overlap" "integrated though x and y both rewrite f"
else
  [[ "$out" == *"y doesn't apply in merge order"* && "$out" == *"  f"* ]] \
    && ok "a real overlap fails, naming the member, commit and file" \
    || bad "overlap message" "$out"
fi

# git failing without a conflict (the 2026-11-16 flake: a lock held by a concurrent process)
# says nothing about whether the forest merges — exit 2, "couldn't check", never "doesn't apply".
REAL_GIT=$(command -v git)
mkdir -p "$ROOT/shim"
cat > "$ROOT/shim/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  [[ \$a == --abort ]] && exec "$REAL_GIT" "\$@"
done
for a in "\$@"; do
  [[ \$a == cherry-pick ]] && { echo "fatal: Unable to create '.git/index.lock': File exists." >&2; exit 128; }
done
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$ROOT/shim/git"
out=$(PATH="$ROOT/shim:$PATH" "$INTEGRATE" p 2>&1); rc=$?
[[ $rc == 2 && "$out" == *"couldn't check"* && "$out" == *"index.lock"* && "$out" != *"doesn't apply"* ]] \
  && ok "a failure that isn't a conflict says it couldn't check, with git's reason, never that the forest doesn't merge" \
  || bad "non-conflict failure" "rc=$rc $out"

echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
