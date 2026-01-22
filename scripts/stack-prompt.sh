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

# Check explicit stack file first (takes precedence)
if [ -f "$STACK_FILE" ]; then
  PARENT=$(grep "^${BRANCH}:" "$STACK_FILE" 2>/dev/null | cut -d: -f2)

  if [ -n "$PARENT" ]; then
    # Branch is explicitly tracked - use explicit mode
    # Walk up to find root and the first branch in this stack (stack_root)
    pos=0
    current="$BRANCH"
    stack_root=""
    while true; do
      p=$(grep "^${current}:" "$STACK_FILE" 2>/dev/null | cut -d: -f2)
      [ -z "$p" ] && break
      ((pos++))
      stack_root="$current"  # last tracked branch before root
      current="$p"
    done
    root="$current"

    # Count total tracked branches in THIS stack only (from stack_root down)
    total=0
    count_descendants() {
      local b="$1"
      for child in $(grep ":${b}$" "$STACK_FILE" 2>/dev/null | cut -d: -f1); do
        ((total++))
        count_descendants "$child"
      done
    }
    [ -n "$stack_root" ] && { ((total++)); count_descendants "$stack_root"; }
  fi
fi

# If not explicitly tracked, try convention mode
if [ -z "$PARENT" ] && [ -f "$CONVENTION_FILE" ]; then
  PREFIX=$(grep -o '"prefix"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONVENTION_FILE" 2>/dev/null | cut -d'"' -f4)
  ROOT=$(grep -o '"root"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONVENTION_FILE" 2>/dev/null | cut -d'"' -f4)

  if [ -n "$PREFIX" ]; then
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
    esac
  fi
fi

# If still not tracked, just show branch name
if [ -z "$PARENT" ]; then
  echo "$BRANCH"
  exit 0
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
