#!/bin/zsh
# SwiftBar plugin — prwatch: show & control which PRs/runs are being watched.
#
# <bitbar.title>prwatch tracking</bitbar.title>
# <bitbar.desc>PRs/runs prwatch is actively watching; start a watch by pasting a PR/run.</bitbar.desc>
# <bitbar.author>phil</bitbar.author>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
#
# No refresh interval in the filename → SwiftBar never polls. It refreshes on open and
# whenever a watcher pokes swiftbar://refreshplugin?name=prwatch (on start/stop/finish).

self="$0"
trackdir="$HOME/.cache/prwatch/tracking"

# --- click action: ➕ Watch… → dialog (clipboard-prefilled) → dispatch to prwatch ---
if [[ "$1" == "--prompt" ]]; then
  clip=$(pbpaste 2>/dev/null | head -1 | tr -d '[:space:]')
  [[ "$clip" == <-> || "$clip" == *github.com/* ]] || clip=""   # only prefill if PR# or gh URL
  input=$(osascript \
    -e 'on run argv' \
    -e 'set d to (display dialog "Watch a PR (number or URL) or an Actions run URL:" default answer (item 1 of argv) with title "prwatch" buttons {"Cancel", "Watch"} default button "Watch")' \
    -e 'return text returned of d' \
    -e 'end run' \
    "$clip" 2>/dev/null) || exit 0    # Cancel → no-op
  input=$(print -r -- "$input" | tr -d '[:space:]')
  [[ -n "$input" ]] || exit 0
  log="$HOME/.cache/prwatch"; mkdir -p "$log"
  print -r -- "$(date '+%F %T') dispatch: $input" >> "$log/prompt.log"
  # nohup + subshell → fully detached, SIGHUP-immune, survives SwiftBar reaping the click.
  ( cd "$HOME/coding/loops" && nohup "$HOME/.dotfiles/scripts/prwatch" "$input" \
      >> "$log/prompt.log" 2>&1 </dev/null & )                  # reuses all input forms
  open -g "swiftbar://refreshplugin?name=prwatch" 2>/dev/null
  exit 0
fi

# --- click action: ✗ Stop watching → kill the watcher, prune its marker -------------
if [[ "$1" == "--stop" ]]; then
  marker="$trackdir/$2.tsv"
  if [[ -f "$marker" ]]; then
    pid=$(cut -f6 "$marker" 2>/dev/null)
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null     # TERM trap in prwatch prunes the marker
    rm -f "$marker"
  fi
  open -g "swiftbar://refreshplugin?name=prwatch" 2>/dev/null
  exit 0
fi

# --- render the menu ----------------------------------------------------------------
rows=()
for f in "$trackdir"/*.tsv(N); do
  IFS=$'\t' read -r repo id title url started pid <"$f"
  kill -0 "$pid" 2>/dev/null || { rm -f "$f"; continue }   # watcher gone → prune
  rows+=("${f:t:r}"$'\t'"$repo"$'\t'"$id"$'\t'"$title"$'\t'"$url")
done

n=${#rows}
if (( n )); then echo "👁 $n"; else echo "👁"; fi   # menu-bar badge
echo "---"
echo "➕ Watch a PR or run… | bash=\"$self\" param1=--prompt terminal=false refresh=true"
echo "---"
if (( n == 0 )); then
  echo "No PRs being watched | color=gray"
else
  for r in "${rows[@]}"; do
    IFS=$'\t' read -r key repo id title url <<<"$r"
    echo "${repo}#${id} — ${title} | href=${url}"
    echo "-- ✗ Stop watching | bash=\"$self\" param1=--stop param2=${key} terminal=false refresh=true"
  done
fi
echo "---"
echo "Refresh | refresh=true"
