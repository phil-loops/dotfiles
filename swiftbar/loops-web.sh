#!/bin/zsh
# SwiftBar plugin — loops-web: one click to launch (or reuse) the loops stack
# blessing-ledger web viewer on :62333 and open it in Chrome. The menu-bar item
# is green when the viewer is live, grey when it's down.
#
# <bitbar.title>loops stack web</bitbar.title>
# <bitbar.desc>Launch/reuse the stack web viewer (:62333) and open it in Chrome.</bitbar.desc>
# <bitbar.author>phil</bitbar.author>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
#
# No refresh interval in the filename → SwiftBar refreshes the view on open and
# after each click (every action pokes swiftbar://refreshplugin?name=loops-web).
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"
self="$0"
repo="$HOME/coding/loops"
serve="$HOME/.dotfiles/scripts/stack-review-serve"
port="${STACK_REVIEW_PORT:-62333}"
base="http://127.0.0.1:${port}"
chrome="Google Chrome"

is_up() { curl -sf --max-time 1 "$base/sig" >/dev/null 2>&1; }
poke()  { open -g "swiftbar://refreshplugin?name=loops-web" 2>/dev/null; }

case "${1:-}" in
  --open)
    # Warm: server already live → open it directly in Chrome (explicit, so it's
    # Chrome even if the default browser changes). Cold: start the build+server
    # detached; the serve script opens the URL itself, and since the default
    # browser is Chrome that lands in Chrome too. Detach so it survives SwiftBar
    # reaping the click process.
    if is_up; then
      open -a "$chrome" "${base}/${2:+?branch=$2}"
    else
      ( cd "$repo" && nohup "$serve" "${2:-}" >/dev/null 2>&1 </dev/null & )
    fi
    poke; exit 0 ;;
  --restart)
    lsof -ti "tcp:${port}" 2>/dev/null | xargs kill 2>/dev/null
    ( cd "$repo" && nohup "$serve" >/dev/null 2>&1 </dev/null & )
    poke; exit 0 ;;
  --stop)
    lsof -ti "tcp:${port}" 2>/dev/null | xargs kill 2>/dev/null
    poke; exit 0 ;;
esac

# --- render the menu ----------------------------------------------------------
if is_up; then
  echo "● | color=#3fb950"
  echo "---"
  echo "● viewer live · :${port} | color=#3fb950 href=${base}/"
  echo "Open in Chrome | bash=\"$self\" param1=--open terminal=false"
  echo "---"
  echo "Restart server | bash=\"$self\" param1=--restart terminal=false"
  echo "Stop server | bash=\"$self\" param1=--stop terminal=false color=#d36a36"
else
  echo "○ | color=#8b949e"
  echo "---"
  echo "○ viewer down | color=#8b949e"
  echo "Launch & open in Chrome | bash=\"$self\" param1=--open terminal=false color=#3fb950"
fi
echo "---"
echo "Repo · ~/coding/loops | color=gray"
echo "Refresh | refresh=true"
