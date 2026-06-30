#!/usr/bin/env bash
# Tests for stack-prepush-guard + stack-wip. Builds throwaway repos, feeds the hook
# the same stdin git would, and asserts exit codes. No network, no real remotes.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard="$here/stack-prepush-guard"
wip="$here/stack-wip"
ZERO="0000000000000000000000000000000000000000"

pass=0; fail=0
ok()   { printf '  ✓ %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  ✗ %s\n' "$1"; fail=$((fail+1)); }

# run the guard with given stdin; echoes its exit code
run_guard() { echo "$1" | "$guard" >/dev/null 2>&1; echo $?; }

mkrepo() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name tester
  git -C "$d" config commit.gpgsign false
  echo "$d"
}
sha() { git -C "$1" rev-parse "${2:-HEAD}"; }

echo "stack-prepush-guard"

# --- new branch, all clean commits → allow ---------------------------------
r="$(mkrepo)"
echo a > "$r/a"; git -C "$r" add .; git -C "$r" commit -qm "feat: a"
echo b > "$r/b"; git -C "$r" add .; git -C "$r" commit -qm "fix: b"
code="$(cd "$r" && run_guard "refs/heads/main $(sha "$r") refs/heads/main $ZERO")"
[[ "$code" == 0 ]] && ok "new branch, clean commits → allow (0)" || bad "clean new branch returned $code"

# --- new branch containing a bare 'wip' subject → block --------------------
r="$(mkrepo)"
echo a > "$r/a"; git -C "$r" add .; git -C "$r" commit -qm "feat: a"
echo b > "$r/b"; git -C "$r" add .; git -C "$r" commit -qm "wip"
code="$(cd "$r" && run_guard "refs/heads/main $(sha "$r") refs/heads/main $ZERO")"
[[ "$code" == 1 ]] && ok "bare 'wip' subject → block (1)" || bad "wip subject returned $code"

# --- X-WIP trailer (via stack-wip) → block ---------------------------------
r="$(mkrepo)"
echo a > "$r/a"; git -C "$r" add .; git -C "$r" commit -qm "feat: a"
echo b > "$r/b"; git -C "$r" add .; (cd "$r" && "$wip" "looks innocent" >/dev/null)
code="$(cd "$r" && run_guard "refs/heads/main $(sha "$r") refs/heads/main $ZERO")"
[[ "$code" == 1 ]] && ok "X-WIP trailer (stack-wip) → block (1)" || bad "X-WIP trailer returned $code"
git -C "$r" log -1 --format=%B | grep -qi "^X-WIP: true" && ok "stack-wip stamps X-WIP: true" || bad "stack-wip missing trailer"

# --- fixup!/squash! autosquash subjects → block ----------------------------
r="$(mkrepo)"
echo a > "$r/a"; git -C "$r" add .; git -C "$r" commit -qm "feat: a"
echo b > "$r/b"; git -C "$r" add .; git -C "$r" commit -qm "fixup! feat: a"
code="$(cd "$r" && run_guard "refs/heads/main $(sha "$r") refs/heads/main $ZERO")"
[[ "$code" == 1 ]] && ok "fixup! subject → block (1)" || bad "fixup! returned $code"

# --- existing remote: only NEW commits scanned (old wip already pushed) -----
r="$(mkrepo)"
echo a > "$r/a"; git -C "$r" add .; git -C "$r" commit -qm "wip"   # pretend already on remote
remote="$(sha "$r")"
echo b > "$r/b"; git -C "$r" add .; git -C "$r" commit -qm "feat: b"  # new, clean
code="$(cd "$r" && run_guard "refs/heads/main $(sha "$r") refs/heads/main $remote")"
[[ "$code" == 0 ]] && ok "old wip already on remote, new commit clean → allow (0)" || bad "delta scan returned $code"

# --- existing remote: new commit is wip → block ----------------------------
r="$(mkrepo)"
echo a > "$r/a"; git -C "$r" add .; git -C "$r" commit -qm "feat: a"
remote="$(sha "$r")"
echo b > "$r/b"; git -C "$r" add .; git -C "$r" commit -qm "wip"
code="$(cd "$r" && run_guard "refs/heads/main $(sha "$r") refs/heads/main $remote")"
[[ "$code" == 1 ]] && ok "new wip beyond remote → block (1)" || bad "delta wip returned $code"

# --- ALLOW_WIP_PUSH escape hatch → allow despite wip -----------------------
r="$(mkrepo)"
echo a > "$r/a"; git -C "$r" add .; git -C "$r" commit -qm "wip"
code="$(cd "$r" && echo "refs/heads/main $(sha "$r") refs/heads/main $ZERO" | ALLOW_WIP_PUSH=1 "$guard" >/dev/null 2>&1; echo $?)"
[[ "$code" == 0 ]] && ok "ALLOW_WIP_PUSH=1 overrides → allow (0)" || bad "escape hatch returned $code"

# --- ref deletion (local sha zero) → allow, nothing to scan ----------------
r="$(mkrepo)"
echo a > "$r/a"; git -C "$r" add .; git -C "$r" commit -qm "feat: a"
code="$(cd "$r" && run_guard "(delete) $ZERO refs/heads/old $(sha "$r")")"
[[ "$code" == 0 ]] && ok "ref deletion → allow (0)" || bad "deletion returned $code"

# --- merge commit on a feature branch → block ------------------------------
r="$(mkrepo)"
echo a > "$r/a"; git -C "$r" add .; git -C "$r" commit -qm "feat: a"
def="$(git -C "$r" rev-parse --abbrev-ref HEAD)"
git -C "$r" checkout -qb side
echo c > "$r/c"; git -C "$r" add .; git -C "$r" commit -qm "feat: c"
git -C "$r" checkout -q "$def"
echo b > "$r/b"; git -C "$r" add .; git -C "$r" commit -qm "feat: b"
git -C "$r" merge -q --no-ff side -m "Merge branch 'side'"
mergetip="$(sha "$r")"
code="$(cd "$r" && run_guard "refs/heads/feature $mergetip refs/heads/feature $ZERO")"
[[ "$code" == 1 ]] && ok "merge commit on feature branch → block (1)" || bad "merge commit returned $code"

# --- merge commit + ALLOW_MERGE_PUSH escape hatch → allow ------------------
code="$(cd "$r" && echo "refs/heads/feature $mergetip refs/heads/feature $ZERO" | ALLOW_MERGE_PUSH=1 "$guard" >/dev/null 2>&1; echo $?)"
[[ "$code" == 0 ]] && ok "ALLOW_MERGE_PUSH=1 overrides → allow (0)" || bad "merge escape hatch returned $code"

# --- merge commit but pushing to main → skipped, allow ---------------------
code="$(cd "$r" && run_guard "refs/heads/main $mergetip refs/heads/main $ZERO")"
[[ "$code" == 0 ]] && ok "merge to main → skip/allow (0)" || bad "merge-to-main returned $code"

echo ""
echo "  $pass passed, $fail failed"
[[ "$fail" == 0 ]]
