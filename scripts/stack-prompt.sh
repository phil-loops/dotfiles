#!/bin/bash
# Fast stack info for starship prompt

# Get repo name and stack file location
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
REPO_NAME=$(basename "$REPO_ROOT")
STACK_DIR="$HOME/.local/share/stack/$REPO_NAME"
STACK_FILE="$STACK_DIR/stack"
CONVENTION_FILE="$STACK_DIR/convention"

BRANCH=$(git branch --show-current 2>/dev/null)
[ -z "$BRANCH" ] && exit 0

# Check for convention mode first
if [ -f "$CONVENTION_FILE" ]; then
  PREFIX=$(grep -o '"prefix"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONVENTION_FILE" 2>/dev/null | cut -d'"' -f4)
  ROOT=$(grep -o '"root"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONVENTION_FILE" 2>/dev/null | cut -d'"' -f4)

  if [ -n "$PREFIX" ]; then
    # Check if current branch matches prefix
    case "$BRANCH" in
      "$PREFIX"*)
        # Get all matching branches, sorted by version number
        BRANCHES=$(git branch --list "${PREFIX}*" 2>/dev/null | sed 's/^[* ]*//' | sort -V)
        total=$(echo "$BRANCHES" | grep -c .)
        pos=0
        prev="$ROOT"
        for b in $BRANCHES; do
          ((pos++))
          [ "$b" = "$BRANCH" ] && { PARENT="$prev"; break; }
          prev="$b"
        done
        ;;
      *)
        # On root or non-matching branch - just show branch name
        echo "$BRANCH"
        exit 0
        ;;
    esac
  fi
else
  # Explicit mode
  [ ! -f "$STACK_FILE" ] && exit 0

  # Look up parent
  PARENT=$(grep "^${BRANCH}:" "$STACK_FILE" 2>/dev/null | cut -d: -f2)
  [ -z "$PARENT" ] && exit 0

  # Count depth from root (1 = first branch after root)
  pos=0
  current="$BRANCH"
  while true; do
    p=$(grep "^${current}:" "$STACK_FILE" 2>/dev/null | cut -d: -f2)
    [ -z "$p" ] && break
    ((pos++))
    current="$p"
  done
  root="$current"

  # Count total tracked branches in this chain
  total=0
  count_descendants() {
    local b="$1"
    for child in $(grep ":${b}$" "$STACK_FILE" 2>/dev/null | cut -d: -f1); do
      ((total++))
      count_descendants "$child"
    done
  }
  count_descendants "$root"
fi

[ -z "$PARENT" ] && exit 0

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

# Remote emoji: 🏠 for origin, 🔱 for fork
if [ "$REMOTE" = "origin" ]; then
  REMOTE_EMOJI="🏠"
else
  REMOTE_EMOJI="🔱"
fi

echo "${REMOTE_EMOJI} ${BRANCH}🌱 ${pos}/${total}🤿"
