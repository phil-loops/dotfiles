#!/bin/bash
# Fast stack info for starship prompt

STACK_FILE=".stack"
[ ! -f "$STACK_FILE" ] && exit 0

BRANCH=$(git branch --show-current 2>/dev/null)
[ -z "$BRANCH" ] && exit 0

# Look up parent
PARENT=$(grep "^${BRANCH}:" "$STACK_FILE" 2>/dev/null | cut -d: -f2)
[ -z "$PARENT" ] && exit 0

# Count position in stack (0-indexed, not counting root)
pos=0
current="$BRANCH"
while true; do
  p=$(grep "^${current}:" "$STACK_FILE" 2>/dev/null | cut -d: -f2)
  [ -z "$p" ] && break
  # Only count if parent is also tracked (not the root)
  if grep -q "^${p}:" "$STACK_FILE" 2>/dev/null; then
    ((pos++))
  fi
  current="$p"
done

# Count total tracked branches in this chain
total=0
# Go to root first
current="$BRANCH"
while true; do
  p=$(grep "^${current}:" "$STACK_FILE" 2>/dev/null | cut -d: -f2)
  [ -z "$p" ] && break
  current="$p"
done
root="$current"
# Now count all descendants of root
count_descendants() {
  local b="$1"
  for child in $(grep ":${b}$" "$STACK_FILE" 2>/dev/null | cut -d: -f1); do
    ((total++))
    count_descendants "$child"
  done
}
count_descendants "$root"
((total--))  # 0-indexed max

# Get remote from config or auto-detect
REMOTE=""
if [ -f ".stackrc" ]; then
  REMOTE=$(grep -o '"remote"[[:space:]]*:[[:space:]]*"[^"]*"' .stackrc 2>/dev/null | cut -d'"' -f4)
fi
if [ -z "$REMOTE" ] && [ -f "$HOME/.stackrc" ]; then
  REMOTE=$(grep -o '"remote"[[:space:]]*:[[:space:]]*"[^"]*"' "$HOME/.stackrc" 2>/dev/null | cut -d'"' -f4)
fi
if [ -z "$REMOTE" ]; then
  # Auto-detect: prefer phil-loops if exists
  if git remote | grep -q "^phil-loops$" 2>/dev/null; then
    REMOTE="phil-loops"
  else
    REMOTE="origin"
  fi
fi

echo "📚${BRANCH} ${REMOTE}:${pos}/${total}→${PARENT}"
