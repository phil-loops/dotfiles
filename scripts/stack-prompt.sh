#!/bin/bash
# Stack info for starship prompt (reads stack-branch.*; legacy git-town-branch.* supported).

BRANCH=$(git branch --show-current 2>/dev/null)
[ -z "$BRANCH" ] && exit 0

# Get all stack parents in one call (new + legacy)
ALL_PARENTS=$(git config --get-regexp "^(stack-branch|git-town-branch)\..*\.parent$" 2>/dev/null)
MAIN_BRANCH=$(git config stack.main-branch 2>/dev/null \
           || git config git-town.main-branch 2>/dev/null \
           || echo "main")

# Look up parent for a branch. Prefer the new key if both are set.
lookup_parent() {
  local b="$1"
  local p
  p=$(echo "$ALL_PARENTS" | grep "^stack-branch\.${b}\.parent " | cut -d' ' -f2)
  if [ -z "$p" ]; then
    p=$(echo "$ALL_PARENTS" | grep "^git-town-branch\.${b}\.parent " | cut -d' ' -f2)
  fi
  echo "$p"
}

PARENT=$(lookup_parent "$BRANCH")

if [ -z "$PARENT" ]; then
  echo "$BRANCH"
  exit 0
fi

# Walk up to find stack root (first branch whose parent is main)
pos=1
current="$BRANCH"
stack_root=""
while true; do
  p=$(lookup_parent "$current")
  [ -z "$p" ] && break
  if [ "$p" = "$MAIN_BRANCH" ]; then
    stack_root="$current"
    break
  fi
  ((pos++))
  current="$p"
done

# If we didn't find a stack root, not in a proper stack
[ -z "$stack_root" ] && { echo "$BRANCH"; exit 0; }

# Count total by walking down from stack root (not main)
total=1  # count the root itself
count_stack() {
  local b="$1"
  for child in $(echo "$ALL_PARENTS" | grep " ${b}$" | sed -E 's/(stack-branch|git-town-branch)\.(.*)\.parent.*/\2/'); do
    ((total++))
    count_stack "$child"
  done
}
count_stack "$stack_root"

# Detect remote
if git remote 2>/dev/null | grep -q "^phil-loops$"; then
  REMOTE_EMOJI="🔱"
else
  REMOTE_EMOJI="🏠"
fi

echo "${REMOTE_EMOJI} ${BRANCH}🌱 ${pos}/${total}🤿"
