#!/usr/bin/env bash
# test-prepush-todo-guard.sh — exercise the TODO push guard in a throwaway repo.
#
# Builds a repo whose origin URL looks like the shared one, commits TODOs on a
# branch, and asserts the guard's verdict for each ack state. No network, no
# effect on any real repo.
set -uo pipefail

GUARD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prepush-todo-guard"
SHARED_URL="git@github.com:Loops-so/loops.git"
FORK_URL="git@github.com:phil-loops/loops.git"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0; fail=0
check() {  # check <name> <expected-exit> <actual-exit> [haystack] [needle]
  local name="$1" want="$2" got="$3" hay="${4:-}" needle="${5:-}"
  if [ "$want" != "$got" ]; then
    echo "✗ $name — expected exit $want, got $got"; fail=$((fail + 1)); return
  fi
  if [ -n "$needle" ] && ! printf '%s' "$hay" | grep -q -- "$needle"; then
    echo "✗ $name — output missing: $needle"; printf '%s\n' "$hay" | sed 's/^/    /'
    fail=$((fail + 1)); return
  fi
  echo "✓ $name"; pass=$((pass + 1))
}

run() {  # run <remote-url> → guard output on stdout, exit in $?
  PUSH_SHA="$(git -C "$repo" rev-parse HEAD)" \
  PUSH_REF="refs/heads/$(git -C "$repo" symbolic-ref --short HEAD)" \
    bash -c 'cd "$1" && "$2" origin "$3" 2>&1' _ "$repo" "$GUARD" "$1"
}

repo="$tmp/repo"
git init -q "$repo"
git -C "$repo" config user.email t@t.t
git -C "$repo" config user.name t
git -C "$repo" remote add origin "$SHARED_URL"
echo base > "$repo/f.ts"
git -C "$repo" add f.ts
git -C "$repo" commit -qm base
git -C "$repo" update-ref refs/remotes/origin/main HEAD
git -C "$repo" checkout -qb feature

# ── clean branch ────────────────────────────────────────────────────────────────
echo "no markers here" >> "$repo/f.ts"
git -C "$repo" commit -qam clean
out=$(run "$SHARED_URL"); check "clean branch passes" 0 $? "$out"

# ── an unticketed TODO still blocks ─────────────────────────────────────────────
echo "// TODO: come back to this" >> "$repo/f.ts"
git -C "$repo" commit -qam todo
out=$(run "$SHARED_URL"); check "unticketed TODO blocks" 1 $? "$out" "unacked TODO"

# ── a fork push is never guarded ────────────────────────────────────────────────
out=$(run "$FORK_URL"); check "fork push unguarded" 0 $? "$out"

# ── env bypass ──────────────────────────────────────────────────────────────────
out=$(TODO_GUARD=0 run "$SHARED_URL"); check "TODO_GUARD=0 bypasses" 0 $? "$out"

# ── a ticketed TODO blocks until acked, and names the ack command ───────────────
git -C "$repo" reset -q --hard HEAD~1
echo "// TODO: Fix in LOO-5922" >> "$repo/f.ts"
git -C "$repo" commit -qam ticketed
out=$(run "$SHARED_URL"); check "ticketed TODO blocks unacked" 1 $? "$out" "stack-todo-ack 'LOO-5922"

git -C "$repo" config --add branch.feature.stack-todo-ack 'LOO-5922 — reviewer asked on #10564'
out=$(run "$SHARED_URL"); check "acked ticket clears" 0 $? "$out"

# ── the ack covers only its own ticket ──────────────────────────────────────────
echo "// TODO: also LOO-9999 someday" >> "$repo/f.ts"
git -C "$repo" commit -qam second
out=$(run "$SHARED_URL"); check "a different ticket still blocks" 1 $? "$out" "LOO-9999"
check "acked line not re-reported" 1 1 "$out" "1 unacked TODO"

# ── case-insensitive ack, and the ack is per-branch ─────────────────────────────
git -C "$repo" config --add branch.feature.stack-todo-ack 'loo-9999 lowercase ack'
out=$(run "$SHARED_URL"); check "ack matching ignores case" 0 $? "$out"

git -C "$repo" checkout -qb other
out=$(run "$SHARED_URL"); check "another branch does not inherit acks" 1 $? "$out" "unacked TODO"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
