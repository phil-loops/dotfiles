#!/usr/bin/env bash
# test-stack-members.sh — a forest's members are the branches tagged into it (branch.<b>.stack-project),
# the registry list is only their order, and stack-registry is its one checked, logged writer.
# 2026-11-18: cite-what-ses-saw fell out of disable-evidence's registry (a re-add hit .git/config's
# lock mid unset-all + re-add) while its tag still named the forest, and the merge-order readers
# dropped it. A temp repo, no remote.
set -u
here="$(cd "$(dirname "$0")" && pwd -P)"
T=$(mktemp -d "${TMPDIR:-/tmp}/test-stack-members.XXXXXX"); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
cd "$T" && git init -q -b main r && cd r
git commit -q --allow-empty -m root
git update-ref refs/remotes/origin/main main
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
mk() { git branch "$1" main; git config "branch.$1.stack-parent" "$2"; git config "branch.$1.stack-project" p
       git config "branch.$1.description" "do $1"; }
mk root main; mk lost root; mk kid lost; mk a.b main; mk axb main
for b in root kid a.b axb; do git config --add stack-project.p.branch "$b"; done   # 'lost' fell out

[ "$("$here/stack-members" p | xargs)" = "root kid a.b axb lost" ] \
  && ok "members: every tagged branch, registry order first, the unlisted after" \
  || bad "members: got '$("$here/stack-members" p | xargs)'"

order=$(python3 "$here/stack-merge-rank" p | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["order"]))')
[[ " $order " == *" lost "* && " $order " == *" kid "* ]] && ok "merge order keeps the branch the registry lost" || bad "merge order: '$order'"

out=$("$here/stack-doctor" p 2>&1); rc=$?
{ [ $rc -eq 1 ] && echo "$out" | grep -q "≠ lost — tagged p but missing from its registry: stack-registry add p lost"; } \
  && ok "doctor fails loud on the lost entry, naming the mend" || { bad "doctor rc=$rc"; echo "$out"; }

"$here/stack-registry" add p lost --via test
out=$("$here/stack-doctor" p 2>&1); rc=$?
[ $rc -eq 0 ] && ! echo "$out" | grep -q "≠" && ok "doctor is quiet once the registry agrees" || { bad "doctor rc=$rc after mend"; echo "$out"; }

# a removal takes exactly its value — 'a.b' is not a pattern that also matches 'axb'
"$here/stack-registry" remove p a.b --via test
[ "$(git config --get-all stack-project.p.branch | xargs)" = "root kid axb lost" ] \
  && ok "remove drops exactly its own entry" || bad "remove: '$(git config --get-all stack-project.p.branch | xargs)'"

# another writer holds .git/config: the one call waits it out instead of losing the entry
touch .git/config.lock; ( sleep 0.4; rm -f .git/config.lock ) &
"$here/stack-registry" remove p axb --via test; rc=$?; wait
[ $rc -eq 0 ] && [ "$(git config --get-all stack-project.p.branch | xargs)" = "root kid lost" ] \
  && ok "a held config lock is waited out; the survivors stay" || bad "lock: rc=$rc '$(git config --get-all stack-project.p.branch | xargs)'"

# every change is logged with who made it
log=$("$here/stack-registry" log p)
[ "$(echo "$log" | wc -l | tr -d ' ')" = "3" ] && echo "$log" | grep -q $'\tremove\tp\taxb\ttest\t' \
  && ok "every add and remove is logged with its caller" || { bad "log"; echo "$log"; }

# a lock that never frees: the failure is reported, not swallowed
touch .git/config.lock
"$here/stack-registry" add p late --via test 2>/dev/null; rc=$?; rm -f .git/config.lock
[ $rc -eq 1 ] && ok "a write that can't land exits 1" || bad "stuck lock rc=$rc"
exit $fail
