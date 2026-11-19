#!/usr/bin/env bash
. "$(dirname "$0")/testenv.sh"   # git here ignores the machine's config
# test-stack-doctor-parent.sh — stack-doctor flags a branch whose stack-parent no longer exists
# (2026-11-17: a merged parent was deleted with its children still naming it). A temp repo with
# no remote: nothing is fetched or pushed.
set -u
here="$(cd "$(dirname "$0")" && pwd -P)"
T=$(mktemp -d "${TMPDIR:-/tmp}/test-doctor-parent.XXXXXX"); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
cd "$T" && git init -q -b main r && cd r
git commit -q --allow-empty -m root
git checkout -q -b c && echo c > c.txt && git add c.txt && git commit -q -m c1
git checkout -q -b ok main && echo o > o.txt && git add o.txt && git commit -q -m o1
git checkout -q main
git config branch.c.stack-parent gone-parent
git config branch.c.stack-project p
git config branch.ok.stack-parent main
git config branch.ok.stack-project p
git config --add stack-project.p.branch c
git config --add stack-project.p.branch ok
out=$("$here/stack-doctor" p 2>&1)
fail=0
echo "$out" | grep -q "c .*PARENT GONE — 'gone-parent'" && echo "ok   a child of a deleted parent is flagged" || { echo "FAIL no PARENT GONE for c"; echo "$out"; fail=1; }
echo "$out" | grep -E "ok( |$)" | grep -q "PARENT GONE" && { echo "FAIL a branch on main was flagged"; fail=1; } || echo "ok   a branch on main is not flagged"
exit $fail
