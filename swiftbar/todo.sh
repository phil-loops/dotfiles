#!/bin/zsh
# SwiftBar plugin — todo: a quick parking lot. Jot one-liners to start later
# without building a branch/stack. Backed by ~/todo.md ("- [ ] item" lines),
# editable anywhere; click an item to check it off, ➕ to park a new one.
#
# <bitbar.title>todo parking lot</bitbar.title>
# <bitbar.desc>Park one-line tasks to pick up later. Backed by ~/todo.md.</bitbar.desc>
# <bitbar.author>phil</bitbar.author>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
#
# No refresh interval → refreshes on open + via swiftbar://refreshplugin?name=todo.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"
self="$0"
file="$HOME/todo.md"
[[ -f "$file" ]] || print -- "# todo — park one-liners to pick up later (no stack required)\n" > "$file"

# --- ➕ park a task: dialog (clipboard-prefilled) → append a "- [ ]" line ---
if [[ "$1" == "--add" ]]; then
  clip=$(pbpaste 2>/dev/null | head -1 | tr '\t\n' '  ')
  input=$(osascript \
    -e 'on run argv' \
    -e 'set d to (display dialog "Park a task:" default answer (item 1 of argv) with title "todo" buttons {"Cancel", "Park"} default button "Park")' \
    -e 'return text returned of d' \
    -e 'end run' \
    "$clip" 2>/dev/null) || exit 0
  input="${input//$'\n'/ }"
  [[ -n "${input// /}" ]] || exit 0
  print -r -- "- [ ] $input" >> "$file"
  open -g "swiftbar://refreshplugin?name=todo" 2>/dev/null
  exit 0
fi

# --- ✓ check off: flip line N from "[ ]" to "[x]" (by line number — robust to text) ---
if [[ "$1" == "--done" ]]; then
  [[ "$2" == <-> ]] && sed -i '' "${2}s/^- \[ \]/- [x]/" "$file" 2>/dev/null
  open -g "swiftbar://refreshplugin?name=todo" 2>/dev/null
  exit 0
fi

# --- ✎ edit the whole list ---
if [[ "$1" == "--edit" ]]; then
  open -t "$file" 2>/dev/null
  exit 0
fi

# --- render ---
# open items as "lineno:text" (lineno drives check-off; survives reorder between renders)
items=("${(@f)$(grep -nE '^- \[ \] ' "$file" 2>/dev/null)}")
n=${#items}
(( n )) && echo "📝 $n" || echo "📝"
echo "---"
echo "➕ Park a task… | bash=\"$self\" param1=--add terminal=false refresh=true"
echo "✎ Edit list | bash=\"$self\" param1=--edit terminal=false"
echo "---"
if (( n == 0 )); then
  echo "nothing parked | color=gray"
else
  for it in "${items[@]}"; do
    lineno="${it%%:*}"
    text="${${it#*:}#- \[ \] }"
    echo "☐ ${text} | bash=\"$self\" param1=--done param2=${lineno} terminal=false refresh=true"
  done
fi
echo "---"
echo "Refresh | refresh=true"
