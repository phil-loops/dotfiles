#!/usr/bin/env bash
# Tests for stack-gates — config-driven gate running with JSON verdict.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gates="$here/stack-gates"

pass=0; fail=0
ok()  { printf '  ✓ %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  ✗ %s\n' "$1"; fail=$((fail+1)); }

mkrepo() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false
  echo x > "$d/x"; git -C "$d" add .; git -C "$d" commit -qm init
  echo "$d"
}
field() { python3 -c "import sys,json; print(json.load(sys.stdin)$1)"; }

echo "stack-gates"

# no gates configured → ok:true with a note
r="$(mkrepo)"
out="$(cd "$r" && "$gates")"
[[ "$(echo "$out" | field "['ok']")" == "True" ]] && ok "no gates → ok:true" || bad "no gates: $out"
[[ "$(echo "$out" | field ".get('note','')" | grep -c "no gates")" == "1" ]] && ok "no gates → note present" || bad "no note: $out"

# one passing gate → ok:true
r="$(mkrepo)"
git -C "$r" config --add stack-gates.cmd "always-pass::true"
out="$(cd "$r" && "$gates")"
[[ "$(echo "$out" | field "['ok']")" == "True" ]] && ok "passing gate → ok:true" || bad "pass gate: $out"
[[ "$(echo "$out" | field "['gates'][0]['name']")" == "always-pass" ]] && ok "gate name reported" || bad "name: $out"

# one failing gate → ok:false, summary captured
r="$(mkrepo)"
git -C "$r" config --add stack-gates.cmd "boom::echo nope >&2; false"
out="$(cd "$r" && "$gates")"
[[ "$(echo "$out" | field "['ok']")" == "False" ]] && ok "failing gate → ok:false" || bad "fail gate: $out"
[[ "$(echo "$out" | field "['gates'][0]['summary']" | grep -c nope)" == "1" ]] && ok "failure summary captured" || bad "summary: $out"

# mixed: pass + fail → ok:false
r="$(mkrepo)"
git -C "$r" config --add stack-gates.cmd "a::true"
git -C "$r" config --add stack-gates.cmd "b::false"
out="$(cd "$r" && "$gates")"
[[ "$(echo "$out" | field "['ok']")" == "False" ]] && ok "any failure → ok:false" || bad "mixed: $out"
n="$(echo "$out" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['gates']))")"
[[ "$n" == 2 ]] && ok "both gates reported" || bad "gate count $n"

# gate exit code: process exits 0 (verdict is in JSON, not exit code)
r="$(mkrepo)"
git -C "$r" config --add stack-gates.cmd "b::false"
(cd "$r" && "$gates" >/dev/null); [[ $? == 0 ]] && ok "process exits 0 (verdict in JSON)" || bad "nonzero exit"

echo ""
echo "  $pass passed, $fail failed"
[[ "$fail" == 0 ]]
