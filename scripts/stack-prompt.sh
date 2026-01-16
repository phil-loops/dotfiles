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
  child=$(grep ":${current}$" "$STACK_FILE" 2>/dev/null | head -1 | cut -d: -f1)
  [ -z "$child" ] && break
  current="$child"
  ((total++))
done

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

# Shorten remote name for display
case "$REMOTE" in
  phil-loops) REMOTE_SHORT="phil" ;;
  loops-so)   REMOTE_SHORT="team" ;;
  origin)     REMOTE_SHORT="origin" ;;
  *)          REMOTE_SHORT="$REMOTE" ;;
esac

echo "📚${REMOTE_SHORT}:${count}/${total}→${PARENT}"
