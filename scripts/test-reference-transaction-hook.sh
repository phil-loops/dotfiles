#!/usr/bin/env bash
# test-reference-transaction-hook.sh — hooks/loops-reference-transaction refuses any move of a
# published branch (origin/<b> exists) that drops commits origin already has, for every tool and raw
# git alike (2026-11-18: a raw rebase script rewrote cite-what-ses-saw, #11659). Fast-forwards,
# catch-up merges, creation, deletion and a reset onto origin pass; STACK_REWRITE_PUBLISHED names a
# deliberate rewrite, and stack-restack names its pushed-but-no-PR drafts. Temp repos, no network.
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$S/../hooks/loops-reference-transaction"
ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/reftx.XXXXXX")" && pwd -P)"; trap 'rm -rf "$ROOT"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1: $2"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t STACK_RESTACK_OPEN_PR_HEADS=" pr "
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE STACK_REWRITE_PUBLISHED

git init -q --bare "$ROOT/origin.git"
git init -q -b main "$ROOT/repo"; cd "$ROOT/repo"
git remote add origin "$ROOT/origin.git"
ln -s "$HOOK" .git/hooks/reference-transaction
echo base > f; git add f; git commit -qm base; git push -q origin main
mk() { git checkout -q -b "$1" "$2"; echo "$1" > "$1.txt"; git add "$1.txt"; git commit -qm "$1"
       git config "branch.$1.stack-parent" "$2"; git config "branch.$1.stack-project" proj; git config --add stack-project.proj.branch "$1"; }
mk pr main; git push -q origin pr
P0=$(git rev-parse pr)
git checkout -q main; echo m1 > m1; git add m1; git commit -qm m1; git push -q origin main

git checkout -q pr
git rebase -q main >/dev/null 2>&1; rc=$?
git rebase --abort >/dev/null 2>&1
[[ $rc -ne 0 && "$(git rev-parse pr)" == "$P0" ]] && ok "a rebase of a published branch is refused" || bad "rebase" "rc=$rc"
git commit -q --amend -m "reworded" >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 && "$(git rev-parse pr)" == "$P0" ]] && ok "an amend of a pushed commit is refused" || bad "amend" "rc=$rc"
git checkout -q main
out=$(git branch -f pr main 2>&1); rc=$?
git checkout -q pr
[[ $rc -ne 0 && "$out" == *"STACK_REWRITE_PUBLISHED=pr"* ]] && ok "a branch -f says how to replace a draft on purpose" || bad "branch -f" "$out"

echo more > more; git add more; git commit -qm more && ok "a commit on top passes" || bad "commit on top" ""
git merge -q --no-edit main >/dev/null 2>&1 && ok "a catch-up merge passes" || bad "merge" ""
git reset -q --hard origin/pr && ok "a reset onto origin's copy passes" || bad "reset to origin" ""
STACK_REWRITE_PUBLISHED=pr git rebase -q main && ok "a named rewrite passes" || bad "override" ""
git reset -q --hard origin/pr
git checkout -q main; git branch -D pr -q && ok "deleting a published branch (contract) passes" || bad "delete" ""
git branch pr "$P0" && ok "creating a branch passes" || bad "create" ""

# stack-restack: a pushed draft with no open PR still restacks; an open-PR branch is left alone
mk draft main; git push -q origin draft
git checkout -q main; echo m2 > m2; git add m2; git commit -qm m2; git push -q origin main
git config branch.pr.stack-parent main; git config branch.pr.stack-project proj
out=$("$S/stack-restack" proj --no-claude --no-classify 2>&1)
git merge-base --is-ancestor origin/main draft && ok "stack-restack still restacks a pushed draft with no PR" || bad "draft restack" "$out"
[[ "$(git rev-parse pr)" == "$P0" ]] && ok "…and leaves the open-PR branch alone" || bad "pr moved" "$out"
echo "--- $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ))
