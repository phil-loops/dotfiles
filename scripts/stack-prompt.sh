#!/bin/bash
# Stack info for starship prompt (reads stack-branch.*).

BRANCH=$(git branch --show-current 2>/dev/null)
[ -z "$BRANCH" ] && exit 0

ALL_PARENTS=$(git config --get-regexp "^stack-branch\..*\.parent$" 2>/dev/null)
MAIN_BRANCH=$(git config stack.main-branch 2>/dev/null || echo "main")

# Exact-match lookups via awk literal field comparison. Branch names contain
# dots and slashes, so the old grep that interpolated the name into a regex
# mis-matched on shared prefixes/suffixes; awk compares the whole field
# literally. (No associative arrays — must run under macOS bash 3.2.)
lookup_parent() {
  awk -v want="stack-branch.$1.parent" '$1==want{print $2; exit}' <<<"$ALL_PARENTS"
}
children_of() {
  awk -v parent="$1" '$2==parent{k=$1; sub(/^stack-branch\./,"",k); sub(/\.parent$/,"",k); print k}' <<<"$ALL_PARENTS"
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
  local child d
  for child in $(children_of "$b"); do
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
