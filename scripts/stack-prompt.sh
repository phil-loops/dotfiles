#!/bin/bash
# Fast stack info for starship prompt

STACK_FILE=".stack"
[ ! -f "$STACK_FILE" ] && exit 0

BRANCH=$(git branch --show-current 2>/dev/null)
[ -z "$BRANCH" ] && exit 0

# Look up parent
PARENT=$(grep "^${BRANCH}:" "$STACK_FILE" 2>/dev/null | cut -d: -f2)
[ -z "$PARENT" ] && exit 0

# Count position in stack
count=1
current="$BRANCH"
while true; do
  p=$(grep "^${current}:" "$STACK_FILE" 2>/dev/null | cut -d: -f2)
  [ -z "$p" ] && break
  current="$p"
  ((count++))
done

# Count total depth from root
total=$count
current="$BRANCH"
while true; do
  # Find children
  child=$(grep ":${current}$" "$STACK_FILE" 2>/dev/null | head -1 | cut -d: -f1)
  [ -z "$child" ] && break
  current="$child"
  ((total++))
done

echo "📚${count}/${total}→${PARENT}"
