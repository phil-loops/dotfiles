#!/bin/bash
# Stack info for starship prompt (reads stack-branch.*).

BRANCH=$(git branch --show-current 2>/dev/null)
[ -z "$BRANCH" ] && exit 0

ALL_PARENTS=$(git config --get-regexp "^stack-branch\..*\.parent$" 2>/dev/null)
MAIN_BRANCH=$(git config stack.main-branch 2>/dev/null || echo "main")

lookup_parent() {
  echo "$ALL_PARENTS" | grep "^stack-branch\.$1\.parent " | cut -d' ' -f2
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

# Total = current depth + longest descendant chain from current branch.
# Walking the root's full subtree conflates sibling stacks that share a root
# (e.g. two projects rooted at goals/shared-validators) into one total.
max_descend_depth() {
  local b="$1"
  local max=0
  for child in $(echo "$ALL_PARENTS" | grep " ${b}$" | sed -E 's/stack-branch\.(.*)\.parent.*/\1/'); do
    local d
    d=$(max_descend_depth "$child")
    d=$((d + 1))
    [ $d -gt $max ] && max=$d
  done
  echo $max
}
descend=$(max_descend_depth "$BRANCH")
total=$((pos + descend))

# Detect remote
if git remote 2>/dev/null | grep -q "^phil-loops$"; then
  REMOTE_EMOJI="🔱"
else
  REMOTE_EMOJI="🏠"
fi

echo "${REMOTE_EMOJI} ${BRANCH}🌱 ${pos}/${total}🤿"
