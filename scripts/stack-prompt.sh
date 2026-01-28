#!/bin/bash
# Stack info for starship prompt using git-town

BRANCH=$(git branch --show-current 2>/dev/null)
[ -z "$BRANCH" ] && exit 0

# Check if this branch has a git-town parent
PARENT=$(git config "git-town-branch.${BRANCH}.parent" 2>/dev/null)

if [ -z "$PARENT" ]; then
  # Not in a stack, just show branch name
  echo "$BRANCH"
  exit 0
fi

# Walk up to find root and count position
pos=1
current="$BRANCH"
while true; do
  p=$(git config "git-town-branch.${current}.parent" 2>/dev/null)
  [ -z "$p" ] && break
  ((pos++))
  current="$p"
done
root="$current"

# Count total branches in this stack (walk down from root)
total=0
count_stack() {
  local b="$1"
  # Find all branches that have $b as parent
  for child in $(git config --get-regexp "^git-town-branch\..*\.parent$" 2>/dev/null | grep " ${b}$" | sed 's/git-town-branch\.\(.*\)\.parent.*/\1/'); do
    ((total++))
    count_stack "$child"
  done
}
count_stack "$root"

echo "${BRANCH} ${pos}/${total}"
