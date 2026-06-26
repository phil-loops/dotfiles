#!/usr/bin/env bash
# test-stack-bless.sh — isolated harness for the dotfiles "blessing" system.
#
# Builds throwaway git repos under a mktemp dir and drives the REAL scripts
#   scripts/stack-bless          (writes/removes both ledgers)
#   scripts/stack-forest --node  (viewer's per-node status + diffs)
#   scripts/stack-blessed-status (CLI status classifier)
# asserting per-file bless status across rebases.
#
# This is the decision gate for whether the patch-id "contribution" bless key
# (stack-blessed-contrib.json) survives rebases, or should be dropped in favor
# of the simpler content-blob key (stack-blessed.json).
#
# Self-contained, re-runnable, cleans up its temp dirs, exits non-zero on any
# failed assertion, prints a PASS/FAIL table.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLESS="$SCRIPTS_DIR/stack-bless"
FOREST="$SCRIPTS_DIR/stack-forest"
STATUS="$SCRIPTS_DIR/stack-blessed-status"

for s in "$BLESS" "$FOREST" "$STATUS"; do
  [[ -x "$s" ]] || { echo "missing or non-executable script: $s" >&2; exit 3; }
done
command -v jq >/dev/null || { echo "jq required" >&2; exit 3; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/stack-bless-test.XXXXXX")"
cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT

PASS=0; FAIL=0
declare -a ROWS

record() { # name result detail
  # PASS/FAIL are real assertions; OBSERVED/CONFIRMED/etc. are observational and
  # never count as failures (T2 and T7 only report actual behavior).
  ROWS+=("$1|$2|$3")
  case "$2" in
    PASS) PASS=$((PASS+1));;
    FAIL) FAIL=$((FAIL+1));;
  esac
}

assert_eq() { # label expected actual  -> echoes PASS/FAIL, sets ASSERT_OK
  local label="$1" exp="$2" act="$3"
  if [[ "$exp" == "$act" ]]; then
    ASSERT_OK=1
    echo "    ok: $label = '$act'"
  else
    ASSERT_OK=0
    echo "    FAIL: $label — expected '$exp', got '$act'" >&2
  fi
}

# --- helpers that drive the real scripts in a given repo ------------------

mkrepo() { # dir
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  git -C "$d" config stack.main-branch main
}

# file-level status from stack-blessed-status (CLI classifier)
status_file() { # repo branch path
  ( cd "$1" && "$STATUS" "$2" ) \
    | jq -r --arg f "$3" '.files[] | select(.path==$f) | .status'
}

# file-level status from stack-forest --node (the viewer path)
forest_file() { # repo branch path [extra args...]
  local repo="$1" branch="$2" path="$3"; shift 3
  ( cd "$repo" && "$FOREST" --node "$branch" "$@" ) \
    | jq -r --arg f "$path" '.files[] | select(.path==$f) | .status'
}

# whole --node payload (for T7 inspection)
forest_node_json() { # repo branch [extra args...]
  local repo="$1" branch="$2"; shift 2
  ( cd "$repo" && "$FOREST" --node "$branch" "$@" )
}

gitdir() { # repo -> absolute git-common-dir
  git -C "$1" rev-parse --path-format=absolute --git-common-dir
}
ledger_val() { # repo ledger-file branch path -> raw value ("" if none)
  jq -r --arg b "$3" --arg f "$4" '.[$b][$f] // ""' "$(gitdir "$1")/$2" 2>/dev/null
}
ledger_has_contrib() { # repo branch path -> "yes"/"no"
  [[ -n "$(ledger_val "$1" stack-blessed-contrib.json "$2" "$3")" ]] && echo yes || echo no
}
ledger_has_blob() { # repo branch path -> "yes"/"no"
  [[ -n "$(ledger_val "$1" stack-blessed.json "$2" "$3")" ]] && echo yes || echo no
}

echo "=== stack-bless test harness ==="
echo "scripts: $SCRIPTS_DIR"
echo "tmp:     $ROOT"
echo

# =========================================================================
# T1 — rebase survival, clean parent move (UNRELATED upstream commit)
# =========================================================================
echo "[T1] rebase-survival (clean parent move, unrelated upstream commit)"
T1="$ROOT/t1"; mkrepo "$T1"
(
  cd "$T1"
  echo "base" > seed.txt
  git add seed.txt; git commit -qm "seed"
  oldmain=$(git rev-parse HEAD)
  git checkout -q -b feat
  printf 'line1\nline2\nline3\n' > A.txt
  git add A.txt; git commit -qm "add A"
  git config stack-branch.feat.parent main
  echo "$oldmain" > .oldmain
)
oldmain=$(cat "$T1/.oldmain")
( cd "$T1" && "$BLESS" feat >/dev/null )

s_status=$(status_file "$T1" feat A.txt)
s_forest=$(forest_file "$T1" feat A.txt)
assert_eq "T1 pre-rebase stack-blessed-status" clean "$s_status"; pre1=$ASSERT_OK
assert_eq "T1 pre-rebase stack-forest --node" clean "$s_forest"; pre2=$ASSERT_OK
contrib_present=$(ledger_has_contrib "$T1" feat A.txt)
assert_eq "T1 contrib ledger key present" yes "$contrib_present"; pre3=$ASSERT_OK

# advance main with an UNRELATED commit (different file), then rebase --onto
(
  cd "$T1"
  git checkout -q main
  echo "unrelated" > B.txt
  git add B.txt; git commit -qm "unrelated main advance"
  newmain=$(git rev-parse HEAD)
  git rebase -q --onto "$newmain" "$oldmain" feat
)
post_status=$(status_file "$T1" feat A.txt)
post_forest=$(forest_file "$T1" feat A.txt)
assert_eq "T1 post-rebase stack-blessed-status" clean "$post_status"; p1=$ASSERT_OK
assert_eq "T1 post-rebase stack-forest --node" clean "$post_forest"; p2=$ASSERT_OK

if (( pre1 && pre2 && pre3 && p1 && p2 )); then
  record "T1 clean-parent-move" PASS "A stays BLESSED after unrelated rebase (patch-id survived); contrib drove it"
else
  record "T1 clean-parent-move" FAIL "pre($pre1$pre2$pre3) post status=$post_status forest=$post_forest"
fi
echo

# =========================================================================
# T2 — rebase that re-touches the hunk (overlapping/adjacent upstream edit)
# =========================================================================
echo "[T2] rebase that shifts the hunk (adjacent/overlapping upstream edit)"
T2="$ROOT/t2"; mkrepo "$T2"
(
  cd "$T2"
  printf 'a\nb\nc\nd\ne\n' > A.txt
  git add A.txt; git commit -qm "seed with A"
  oldmain=$(git rev-parse HEAD)
  git checkout -q -b feat
  # branch's logical change: insert a NEW line after 'c'
  printf 'a\nb\nc\nBRANCH_LINE\nd\ne\n' > A.txt
  git add A.txt; git commit -qm "feat: insert BRANCH_LINE"
  git config stack-branch.feat.parent main
  echo "$oldmain" > .oldmain
)
oldmain=$(cat "$T2/.oldmain")
( cd "$T2" && "$BLESS" feat >/dev/null )
pre_status=$(status_file "$T2" feat A.txt)
assert_eq "T2 pre-rebase status" clean "$pre_status"; t2pre=$ASSERT_OK
blc_before=$(ledger_val "$T2" stack-blessed-contrib.json feat A.txt)

# upstream edits a line ADJACENT to / overlapping the branch's hunk on main,
# so the merge base & -U0 context shift. Edit 'c' -> 'c_main' (line just above
# the inserted BRANCH_LINE) to force overlap on rebase.
(
  cd "$T2"
  git checkout -q main
  printf 'a\nb\nc_main\nd\ne\n' > A.txt
  git add A.txt; git commit -qm "main: edit c -> c_main (adjacent to feat hunk)"
  newmain=$(git rev-parse HEAD)
  # rebase; resolve conflict KEEPING the branch's logical change (insert BRANCH_LINE)
  # on top of main's c_main edit.
  if ! git rebase -q --onto "$newmain" "$oldmain" feat 2>/dev/null; then
    printf 'a\nb\nc_main\nBRANCH_LINE\nd\ne\n' > A.txt
    git add A.txt
    GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 || git rebase --continue >/dev/null 2>&1 || true
  fi
)
t2_status=$(status_file "$T2" feat A.txt)
t2_forest=$(forest_file "$T2" feat A.txt)
contrib_now=$(ledger_has_contrib "$T2" feat A.txt)
# determine which ledger drives the verdict: contrib present => contrib path
driver="blob"
[[ "$contrib_now" == yes ]] && driver="contrib"
# recompute current patch-id to show whether it shifted
cur_pid=$( cd "$T2" && git diff -U0 main...feat -- A.txt | git patch-id --stable | awk '{print $1}' )
pid_same=no; [[ -n "$cur_pid" && "$cur_pid" == "$blc_before" ]] && pid_same=yes
# confirm a real overlap was resolved: file must carry BOTH main's edit and the branch line
content_ok=no
if ( cd "$T2" && grep -q c_main A.txt && grep -q BRANCH_LINE A.txt ); then content_ok=yes; fi
echo "    info: blessed contrib id was '${blc_before:0:12}...', current contrib id '${cur_pid:0:12}...' (identical=$pid_same)"
echo "    info: post-rebase status=$t2_status (driver=$driver); overlap resolved & both edits present=$content_ok"
# T2 is observational — report ACTUAL behavior, no asserted expected value
record "T2 hunk-shift-rebase" "OBSERVED" \
  "status=$t2_status driver=$driver patch-id-unchanged=$pid_same (overlap-resolved=$content_ok)"
echo

# =========================================================================
# T3 — stale -> re-bless
# =========================================================================
echo "[T3] stale -> re-bless"
T3="$ROOT/t3"; mkrepo "$T3"
(
  cd "$T3"
  echo seed > seed.txt; git add seed.txt; git commit -qm seed
  git checkout -q -b feat
  printf 'x\ny\nz\n' > A.txt; git add A.txt; git commit -qm "add A"
  git config stack-branch.feat.parent main
)
( cd "$T3" && "$BLESS" feat >/dev/null )
b1=$(status_file "$T3" feat A.txt)
assert_eq "T3 initial bless" clean "$b1"; t3a=$ASSERT_OK
# modify A on the branch (new commit -> contribution changes)
(
  cd "$T3"
  printf 'x\ny\nz\nNEW\n' >> A.txt 2>/dev/null || printf 'x\ny\nz\nNEW\n' > A.txt
  git add A.txt; git commit -qm "change A"
)
b2=$(status_file "$T3" feat A.txt)
b2f=$(forest_file "$T3" feat A.txt)
assert_eq "T3 after modify (status)" stale "$b2"; t3b=$ASSERT_OK
assert_eq "T3 after modify (forest)" stale "$b2f"; t3c=$ASSERT_OK
# re-bless single file
( cd "$T3" && "$BLESS" feat --file A.txt >/dev/null )
b3=$(status_file "$T3" feat A.txt)
b3f=$(forest_file "$T3" feat A.txt)
assert_eq "T3 after re-bless (status)" clean "$b3"; t3d=$ASSERT_OK
assert_eq "T3 after re-bless (forest)" clean "$b3f"; t3e=$ASSERT_OK
if (( t3a && t3b && t3c && t3d && t3e )); then
  record "T3 stale->re-bless" PASS "bless->clean, modify->stale (both classifiers), re-bless->clean"
else
  record "T3 stale->re-bless" FAIL "b1=$b1 b2=$b2/$b2f b3=$b3/$b3f"
fi
echo

# =========================================================================
# T7 — base=blessed pill bug (viewer passes --base blessed)
# =========================================================================
echo "[T7] base=blessed pill (stack-forest --node <branch> --base blessed)"
T7="$ROOT/t7"; mkrepo "$T7"
(
  cd "$T7"
  echo seed > seed.txt; git add seed.txt; git commit -qm seed
  git checkout -q -b feat
  printf 'p\nq\nr\n' > A.txt; git add A.txt; git commit -qm "add A"
  git config stack-branch.feat.parent main
)
( cd "$T7" && "$BLESS" feat >/dev/null )
# normal parent base: should list A.txt
normal_json=$(forest_node_json "$T7" feat)
normal_count=$(echo "$normal_json" | jq '.files | length')
# blessed base: "blessed" is not a real ref
blessed_json=$(forest_node_json "$T7" feat --base blessed)
blessed_count=$(echo "$blessed_json" | jq '.files | length' 2>/dev/null || echo "ERR")
ref_exists=$( cd "$T7" && git rev-parse --verify --quiet blessed >/dev/null 2>&1 && echo yes || echo no )
echo "    info: normal --node files=$normal_count ; --base blessed files=$blessed_count ; 'blessed' ref exists=$ref_exists"
if [[ "$blessed_count" == "0" || "$blessed_count" == "ERR" ]]; then
  record "T7 base=blessed pill" "CONFIRMED" "normal=$normal_count files, --base blessed=$blessed_count (empty/erroring diff — bug confirmed)"
else
  record "T7 base=blessed pill" "NOT-REPRODUCED" "--base blessed returned $blessed_count files"
fi
echo

# =========================================================================
# Report
# =========================================================================
echo "============================================================"
echo " RESULTS"
echo "============================================================"
printf "%-22s %-14s %s\n" "CASE" "RESULT" "DETAIL"
printf "%-22s %-14s %s\n" "----" "------" "------"
for row in "${ROWS[@]}"; do
  IFS='|' read -r name res detail <<< "$row"
  printf "%-22s %-14s %s\n" "$name" "$res" "$detail"
done
echo "------------------------------------------------------------"
echo "assert PASS=$PASS  FAIL=$FAIL"
echo

if (( FAIL > 0 )); then
  echo "OVERALL: FAIL"
  exit 1
fi
echo "OVERALL: PASS (observational cases T2/T7 reported above)"
exit 0
