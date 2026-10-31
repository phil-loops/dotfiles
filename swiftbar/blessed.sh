#!/bin/zsh
# SwiftBar plugin — blessed: menu-bar launcher for the blessing-ledger review viewer.
# Verbs — Start (background, no browser), Start + open in Chrome, canopy (the forest viewer, in Show), the
# loops API Postman console (:7070, in Show's API workspace), the mail-map pipeline wiki (:62555), and the bookshelf (:62556). The
# badge ✦ is green when the viewer is live, grey when down.
#
# <bitbar.title>blessed viewer launcher</bitbar.title>
# <bitbar.desc>Start/open the blessing-ledger viewer, or the loops API Postman console.</bitbar.desc>
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
# Resolve the repo's stable port via the same source of truth stack-review-serve uses, so
# the liveness check pings where the server actually binds (per-repo, not the legacy :62333).
port="$("$HOME/.dotfiles/scripts/stack-review-port" "$repo" 2>/dev/null || echo 62333)"
base="http://127.0.0.1:${port}"
serve="$HOME/.dotfiles/scripts/stack-review-serve"
show="$HOME/.dotfiles/scripts/show"
pmport=7070
mailmap="$HOME/.dotfiles/scripts/mail-map-serve"
mmport=62555; mmbase="http://127.0.0.1:${mmport}"
bookshelf="$HOME/.dotfiles/scripts/bookshelf-serve"
bsport=62556; bsbase="http://127.0.0.1:${bsport}"
logs="$HOME/.dotfiles/scripts/loops-logs"
lgport=3900; lgbase="http://127.0.0.1:${lgport}"

poke() { open -g "swiftbar://refreshplugin?name=blessed" 2>/dev/null; }
notify() { osascript -e "display notification \"${1//\"/'}\" with title \"canopy\"" 2>/dev/null; }
# Detach (nohup + subshell) so the server survives SwiftBar reaping the click process.
bg()   { ( cd "$repo" && nohup "$@" >/dev/null 2>&1 </dev/null & ); }

# --- click actions -------------------------------------------------------------------
case "${1:-}" in
  --open)        # reuse-or-start the viewer AND open it (no arg → project picker)
    bg "$serve" "${2:-}"; poke; exit 0 ;;
  --start)       # full build + serve in the background, no browser
    bg "$serve" --no-open; poke; exit 0 ;;
  --restart)     # bounce the server, stay in the background
    lsof -ti "tcp:${port}" 2>/dev/null | xargs kill 2>/dev/null
    bg "$serve" --no-open; poke; exit 0 ;;
  --canopy)      # the forest viewer, in Show's Canopy workspace (which starts the server when it's down).
    # A rebuild runs a minute or so with no window, so it says so in a notification, and so does a failure.
    ( "$show" --canopy 2>&1 </dev/null | while IFS= read -r line; do
        [[ "$line" == *": building"* ]] && notify "building — it opens when done"
        last="$line"
      done
      (( ${pipestatus[1]} )) && notify "didn't open: ${last}"
    ) >/dev/null 2>&1 &
    poke; exit 0 ;;
  --postman)     # the API console, in Show's API workspace, which starts the server when it's down.
    ( nohup "$show" --api >/dev/null 2>&1 </dev/null & )
    poke; exit 0 ;;
  --mailmap)     # the mail-pipeline wiki. Warm → focus it. Cold → start detached, then poll
    # until it answers and open — the server doesn't open a browser itself.
    if curl -sf --max-time 1 "$mmbase/" >/dev/null 2>&1; then
      open "$mmbase/"
    else
      ( nohup "$mailmap" "$mmport" >/dev/null 2>&1 </dev/null &
        for _ in $(seq 1 30); do
          curl -sf --max-time 1 "$mmbase/" >/dev/null 2>&1 && { open "$mmbase/"; break; }
          sleep 0.3
        done ) &
    fi
    poke; exit 0 ;;
  --bookshelf)   # the reading shelves. Same warm/cold dance as the mail map.
    if curl -sf --max-time 1 "$bsbase/shelves" >/dev/null 2>&1; then
      open "$bsbase/"
    else
      ( nohup "$bookshelf" "$bsport" >/dev/null 2>&1 </dev/null &
        for _ in $(seq 1 30); do
          curl -sf --max-time 1 "$bsbase/shelves" >/dev/null 2>&1 && { open "$bsbase/"; break; }
          sleep 0.3
        done ) &
    fi
    poke; exit 0 ;;
  --logs)        # Grafana over the dev logs. loops-logs starts the stack if needed, waits for
    # Grafana to answer, then opens it — detached, since a cold start takes a few seconds.
    ( nohup "$logs" "${2:-open}" >/dev/null 2>&1 </dev/null & )
    poke; exit 0 ;;
esac

# --- render the menu -----------------------------------------------------------------
up=0; curl -sf --max-time 1 "$base/sig" >/dev/null 2>&1 && up=1
mmup=0; curl -sf --max-time 1 "$mmbase/" >/dev/null 2>&1 && mmup=1
bsup=0; curl -sf --max-time 1 "$bsbase/shelves" >/dev/null 2>&1 && bsup=1
lgup=0; curl -sf --max-time 1 "$lgbase/api/health" >/dev/null 2>&1 && lgup=1

# menu-bar badge: ✦ tinted green when the viewer is live, grey when it's down
if (( up )); then
  echo "✦ | color=#3fb950"
else
  echo "✦ | color=#8b949e"
fi
echo "---"
if (( up )); then
  echo "● viewer live · :${port} — open | color=#3fb950 bash=\"$self\" param1=--open terminal=false"
  echo "↻ Restart (background) | bash=\"$self\" param1=--restart terminal=false"
else
  echo "○ viewer down | color=#8b949e"
  echo "▷ Start (background) | bash=\"$self\" param1=--start terminal=false"
  echo "▷ Start + open in Chrome | color=#3fb950 bash=\"$self\" param1=--open terminal=false"
fi
echo "🌲 Canopy | bash=\"$self\" param1=--canopy terminal=false"
echo "⚡ Postman console · :${pmport} | bash=\"$self\" param1=--postman terminal=false"
if (( mmup )); then
  echo "📬 Mail map · :${mmport} — open | color=#3fb950 bash=\"$self\" param1=--mailmap terminal=false"
else
  echo "📬 Mail map · :${mmport} | bash=\"$self\" param1=--mailmap terminal=false"
fi
if (( bsup )); then
  echo "📚 Bookshelf · :${bsport} — open | color=#3fb950 bash=\"$self\" param1=--bookshelf terminal=false"
else
  echo "📚 Bookshelf · :${bsport} | bash=\"$self\" param1=--bookshelf terminal=false"
fi
if (( lgup )); then
  echo "📜 Logs · :${lgport} — open | color=#3fb950 bash=\"$self\" param1=--logs terminal=false"
else
  echo "📜 Logs · :${lgport} | bash=\"$self\" param1=--logs terminal=false"
fi
echo "--Dashboard | bash=\"$self\" param1=--logs param2=open terminal=false"
echo "--Explore (press ▷ Live) | bash=\"$self\" param1=--logs param2=live terminal=false"
(( lgup )) && echo "--Stop | bash=\"$self\" param1=--logs param2=down terminal=false"
echo "---"
echo "Refresh | refresh=true"
