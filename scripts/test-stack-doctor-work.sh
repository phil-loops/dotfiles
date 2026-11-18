#!/usr/bin/env bash
# test-stack-doctor-work.sh — stack-doctor --prune retires branch work whose branch is gone (DESIGN.md round 27, P6),
# never an item's work, another repo's, or one a branch still names. A temp repo and journal; nothing fetched or pushed.
set -u
here="$(cd "$(dirname "$0")" && pwd -P)"
T=$(mktemp -d "${TMPDIR:-/tmp}/test-doctor-work.XXXXXX"); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t CANOPY_WORK_JOURNAL="$T/journal.sqlite3"
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
cd "$T" && git init -q -b main r && cd r
git commit -q --allow-empty -m root
git branch kept
read -r kept gone item other < <(python3 - "$here" <<'PY'
import sys; sys.path.insert(0, sys.argv[1])
from srv import workjournal as wj
j = wj.Journal()
print(j.mint_branch_work("r", "kept"), j.mint_branch_work("r", "deleted"),
      j.work_for_todo("an-item", "inc-1", create=True, repo="r", branch="deleted"), j.mint_branch_work("other-repo", "x"))
PY
)
git config branch.kept.stack-work "$kept"
state() { python3 - "$here" "$1" <<'PY'
import sys; sys.path.insert(0, sys.argv[1])
from srv import workjournal as wj
print("retired" if wj.Journal().work(sys.argv[2])["retired_at"] else "live")
PY
}
fail=0
out=$("$here/stack-doctor" --prune --dry-run 2>&1)
echo "$out" | grep -q "would retire work $gone (branch deleted is gone)" && [ "$(state "$gone")" = live ] \
  && echo "ok   --dry-run names the gone branch's work and retires nothing" || { echo "FAIL dry run"; echo "$out"; fail=1; }
"$here/stack-doctor" --prune >/dev/null 2>&1
[ "$(state "$gone")" = retired ] && echo "ok   the gone branch's work is retired" || { echo "FAIL $gone still live"; fail=1; }
for w in "$kept" "$item" "$other"; do
  [ "$(state "$w")" = live ] || { echo "FAIL $w was retired"; fail=1; }
done
[ "$fail" = 0 ] && echo "ok   a named branch's, an item's and another repo's work stay live"
rm -f "$CANOPY_WORK_JOURNAL"
"$here/stack-doctor" --prune >/dev/null 2>&1
[ ! -e "$CANOPY_WORK_JOURNAL" ] && echo "ok   a prune never creates the journal" || { echo "FAIL prune created the journal"; fail=1; }
exit $fail
