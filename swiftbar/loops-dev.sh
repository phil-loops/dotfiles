#!/bin/zsh
# SwiftBar plugin — loops dev: launch & open the loops dev site (the Next app on
# :3000, started by `task dev`). Status-aware, computed ON OPEN (no polling — same
# as blessed). Click to start the dev server in a tmux window of the `loops`
# session, or open the running site.
#
# <bitbar.title>loops dev</bitbar.title>
# <bitbar.desc>Launch & open the loops dev site; status-aware (on open).</bitbar.desc>
# <bitbar.author>phil</bitbar.author>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
#
# No refresh interval in the filename → SwiftBar refreshes on open and whenever
# something pokes swiftbar://refreshplugin?name=loops-dev. (Deliberately no poll.)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"
self="$0"
repo="$HOME/coding/loops"
port="${LOOPS_DEV_PORT:-3000}"
url="http://localhost:${port}"
session="${STACK_OPEN_TMUX:-loops}"
log="/tmp/loops-dev.log"

is_up() { curl -sf --max-time 1 -o /dev/null "$url" 2>/dev/null; }

# --- click action: start the dev server (only if down), then open the site -----------
# tmux owns the window, so it survives SwiftBar reaping the click process — and you can
# attach to the `dev` window to watch logs / Ctrl-C it. Mirrors the `dev` alias
# (NGROK=false task dev | tee). `exec $SHELL` keeps the window if the task exits.
if [[ "$1" == "--start" ]]; then
  if is_up; then
    open "$url"
    open -g "swiftbar://refreshplugin?name=loops-dev" 2>/dev/null
  else
    tmux has-session -t "$session" 2>/dev/null || tmux new-session -d -s "$session"
    tmux new-window -t "$session" -n dev -c "$repo" \
      "NGROK=false task dev 2>&1 | tee ${log}; exec \$SHELL" 2>/dev/null
    # task dev takes a bit to bind :3000 (services + Next compile). Wait for it before
    # opening so the click doesn't land on a dead page. Backgrounded (&!) so the click
    # returns instantly AND survives SwiftBar reaping it; falls back to opening anyway
    # after the timeout. Poke SwiftBar to re-render once it's up.
    ( for i in {1..90}; do is_up && break; sleep 1; done
      open "$url"
      open -g "swiftbar://refreshplugin?name=loops-dev" 2>/dev/null ) &!
  fi
  exit 0
fi

# --- render the menu -----------------------------------------------------------------
echo "◎ loops"        # static title — no polling, so the title can't show live status
echo "---"
if is_up; then
  echo "● site up · :${port} | color=#3fb950 href=${url}"
  echo "Open site | href=${url}"
  echo "Tail dev log | bash=/usr/bin/tail param1=-f param2=${log} terminal=true"
else
  echo "○ site down — click to launch | color=#d36a36 bash=\"$self\" param1=--start terminal=false"
fi
echo "---"
echo "Refresh | refresh=true"
