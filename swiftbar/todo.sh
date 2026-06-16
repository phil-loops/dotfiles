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

# --- ➕ park a task: dialog (clipboard-prefilled) → store a "- [ ]" line.
# Rich: type "label https://url" or "[label](url)", or just paste a URL → it becomes
# a clickable link; plain text stays plain.
if [[ "$1" == "--add" ]]; then
  clip=$(pbpaste 2>/dev/null | head -1 | tr '\t\n' '  ')
  input=$(osascript \
    -e 'on run argv' \
    -e 'set d to (display dialog "Park a task (include a URL to make it clickable):" default answer (item 1 of argv) with title "todo" buttons {"Cancel", "Park"} default button "Park")' \
    -e 'return text returned of d' \
    -e 'end run' \
    "$clip" 2>/dev/null) || exit 0
  input="${input//$'\n'/ }"
  input="${input#"${input%%[![:space:]]*}"}"; input="${input%"${input##*[![:space:]]}"}"   # trim
  [[ -n "$input" ]] || exit 0
  if [[ "$input" == "["*"]("*")" ]]; then
    line="- [ ] $input"                                              # already a markdown link
  elif [[ "$input" == *http://* || "$input" == *https://* ]]; then
    url="http${input#*http}"; url="${url%%[[:space:]]*}"             # first URL token
    label="${input%%http*}"; label="${label%"${label##*[![:space:]]}"}"   # text before it, rstripped
    [[ -n "$label" ]] || label="$url"                               # bare URL → label = the URL
    line="- [ ] [$label]($url)"
  else
    line="- [ ] $input"                                             # plain
  fi
  print -r -- "$line" >> "$file"
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

# --- ↗ open a todo's link. A blessing-viewer URL (127.0.0.1…?branch=X) is routed
# through stack-review-serve so it reuses-or-starts the server; anything else opens raw.
if [[ "$1" == "--open" ]]; then
  url="$2"
  if [[ "$url" == *"127.0.0.1"*"branch="* ]]; then
    branch="${url##*branch=}"; branch="${branch%%&*}"
    ( cd "$HOME/coding/loops" && nohup "$HOME/.dotfiles/scripts/stack-review-serve" "$branch" >/dev/null 2>&1 </dev/null & )
  else
    open "$url" 2>/dev/null
  fi
  exit 0
fi

# --- render ---
# open items as "lineno:text" (lineno drives check-off; survives reorder between renders).
# NB build the array only when grep matched — `("${(@f)$(empty)}")` yields a single
# EMPTY element (count 1), not an empty array.
items=()
open_lines=$(grep -nE '^- \[ \] ' "$file" 2>/dev/null)
[[ -n "$open_lines" ]] && items=("${(@f)open_lines}")
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
    # markdown link "[label](url)" → clicking the item opens the link; plain text is inert.
    if [[ "$text" == "["*"]("*")" ]]; then
      label="${text#"["}"; label="${label%%"]("*}"
      url="${text#*"]("}"; url="${url%")"}"
      echo "☐ ${label} | bash=\"$self\" param1=--open param2=\"${url}\" terminal=false"
    else
      echo "☐ ${text}"
    fi
    # the explicit check-off — its own action, so clicking the item never marks it done by accident
    echo "-- ✓ mark done | bash=\"$self\" param1=--done param2=${lineno} terminal=false refresh=true"
  done
fi
echo "---"
echo "Refresh | refresh=true"
