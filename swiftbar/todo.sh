#!/bin/zsh
# SwiftBar plugin — todo: a parking lot for one-liners to pick up later (no stack
# required). You ADD/REORDER by editing ~/todo.md in nvim (✎ Edit); the menu just
# lists open items — click one to open its link, "✓ mark done" to check it off.
#
# Item formats in todo.md (all render correctly):
#   - [ ] plain text
#   - [ ] [label](url)
#   - [ ] label https://url        (or a bare URL — auto-linked with a readable label)
#
# <bitbar.title>todo parking lot</bitbar.title>
# <bitbar.desc>One-line tasks to pick up later; edit ~/todo.md in nvim.</bitbar.desc>
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

# A human label for a bare URL: github PR/issue → "repo#num" · the viewer →
# "review: branch" · else the host.
nice_label() {
  local u="$1" p
  case "$u" in
    *github.com/*/pull/*|*github.com/*/issues/*)
      p="${u#*github.com/}"; local num="${u##*/}"
      print -r -- "${${p#*/}%%/*}#${num%%[!0-9]*}" ;;
    *github.com/*/tree/*)
      p="${u#*github.com/}"; print -r -- "${${p#*/}%%/*}@${u##*/tree/}" ;;
    *branch=*) local b="${u##*branch=}"; print -r -- "review: ${b%%&*}" ;;
    *) p="${u#*://}"; p="${p#www.}"; print -r -- "${p%%/*}" ;;
  esac
}

# parse a todo's text into (label, url). echoes "label\turl" (url empty = plain).
parse_item() {
  local text="$1" label url=""
  if [[ "$text" == "["*"]("*")" ]]; then
    label="${text#"["}"; label="${label%%"]("*}"; url="${text#*"]("}"; url="${url%")"}"
  elif [[ "$text" == *http://* || "$text" == *https://* ]]; then
    url="http${text#*http}"; url="${url%%[[:space:]]*}"
    label="${text%%http*}"; label="${label%"${label##*[![:space:]]}"}"
    [[ -n "$label" ]] || label="$(nice_label "$url")"
  else
    label="$text"
  fi
  print -r -- "${label}"$'\t'"${url}"
}

# --- ✎ edit ~/todo.md in nvim (loops tmux) — THE way you add/reorder tasks ---
if [[ "$1" == "--edit" ]]; then
  session="${TODO_TMUX:-loops}"
  if tmux has-session -t "$session" 2>/dev/null; then
    if tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -qx todo; then
      tmux send-keys -t "${session}:todo" Escape ":edit ${file}" Enter 2>/dev/null
      tmux select-window -t "${session}:todo" 2>/dev/null
    else
      tmux new-window -t "$session" -n todo "nvim ${(q)file}"
    fi
    app=$(ps -axo comm 2>/dev/null | grep -ioE 'iTerm|WezTerm|Alacritty|kitty|Ghostty|Terminal' | head -1)
    [[ -n "$app" ]] && osascript -e "tell application \"$app\" to activate" >/dev/null 2>&1
  else
    open -t "$file" 2>/dev/null   # no tmux → default editor
  fi
  exit 0
fi

# --- ↗ open a todo's link. A blessing-viewer URL (…?branch=X) is routed through
# stack-review-serve (reuse-or-start the server); anything else opens raw.
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

# --- ✓ check off line N (flip "[ ]" → "[x]" by line number) ---
if [[ "$1" == "--done" ]]; then
  [[ "$2" == <-> ]] && sed -i '' "${2}s/^- \[ \]/- [x]/" "$file" 2>/dev/null
  open -g "swiftbar://refreshplugin?name=todo" 2>/dev/null
  exit 0
fi

# --- render ---
items=()
open_lines=$(grep -nE '^- \[ \] ' "$file" 2>/dev/null)   # "lineno:- [ ] text"
[[ -n "$open_lines" ]] && items=("${(@f)open_lines}")
n=${#items}
(( n )) && echo "📝 $n" || echo "📝"
echo "---"
echo "✎ Edit in nvim | bash=\"$self\" param1=--edit terminal=false"
echo "---"
if (( n == 0 )); then
  echo "nothing parked — ✎ Edit to add | color=gray"
else
  for it in "${items[@]}"; do
    lineno="${it%%:*}"
    text="${${it#*:}#- \[ \] }"
    IFS=$'\t' read -r label url <<<"$(parse_item "$text")"
    if [[ -n "$url" ]]; then
      echo "☐ ${label} | bash=\"$self\" param1=--open param2=\"${url}\" terminal=false"
    else
      echo "☐ ${label}"
    fi
    echo "-- ✓ mark done | bash=\"$self\" param1=--done param2=${lineno} terminal=false refresh=true"
  done
fi
echo "---"
echo "Refresh | refresh=true"
