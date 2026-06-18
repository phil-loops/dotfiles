#!/bin/zsh
# SwiftBar plugin — blessed: your registered stack-projects, one click to the
# blessing-ledger review viewer. Click a project → reuse-or-start the server and
# open it. The menu-bar "stuff to review later" list.
#
# <bitbar.title>blessed projects</bitbar.title>
# <bitbar.desc>Registered stack-projects; click one to open the blessing-ledger viewer.</bitbar.desc>
# <bitbar.author>phil</bitbar.author>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
#
# No refresh interval in the filename → SwiftBar refreshes on open and whenever
# something pokes swiftbar://refreshplugin?name=blessed.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"
self="$0"
repo="$HOME/coding/loops"
port="${STACK_REVIEW_PORT:-62333}"
base="http://127.0.0.1:${port}"

# --- click action: open <project> (no arg → the project picker) ----------------------
# stack-review-serve reuses a live server or starts one detached, then opens the URL.
# Detach (nohup + subshell) so it survives SwiftBar reaping the click process.
if [[ "$1" == "--open" ]]; then
  ( cd "$repo" && nohup "$HOME/.dotfiles/scripts/stack-review-serve" "${2:-}" >/dev/null 2>&1 </dev/null & )
  open -g "swiftbar://refreshplugin?name=blessed" 2>/dev/null
  exit 0
fi

# --- render the menu -----------------------------------------------------------------
up=0; curl -sf --max-time 1 "$base/sig" >/dev/null 2>&1 && up=1
# unique project names from stack-project.<name>.branch (multivar → dedupe).
# build only when non-empty — `("${(@f)$(empty)}")` is a 1-elem empty array, not empty.
projects=()
plist=$(git -C "$repo" config --get-regexp '^stack-project\..*\.branch$' 2>/dev/null \
  | sed -E 's/^stack-project\.(.*)\.branch .*/\1/' | sort -u)
# drop archived projects (stack-project.<name>.archived=true) — kept registered,
# just hidden here and in the chooser; `loops stack unarchive <name>` restores.
if [[ -n "$plist" ]]; then
  plist=$(while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    [[ "$(git -C "$repo" config --bool stack-project.${n}.archived 2>/dev/null)" == "true" ]] && continue
    echo "$n"
  done <<< "$plist")
fi
[[ -n "$plist" ]] && projects=("${(@f)plist}")
n=${#projects}

echo "✦ ${n}"            # menu-bar badge: number of registered projects
echo "---"
if (( up )); then
  echo "● viewer live · :${port} | color=#3fb950 bash=\"$self\" param1=--open terminal=false"
else
  echo "○ viewer down — click to launch | color=#d36a36 bash=\"$self\" param1=--open terminal=false"
fi
echo "---"
if (( n == 0 )); then
  echo "no stack projects registered | color=gray"
else
  for p in "${projects[@]}"; do
    [[ -n "$p" ]] && echo "✦ ${p} | bash=\"$self\" param1=--open param2=${p} terminal=false"
  done
fi
echo "---"
echo "Refresh | refresh=true"
