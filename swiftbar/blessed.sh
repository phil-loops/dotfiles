#!/bin/zsh
# SwiftBar plugin — blessed: menu-bar launcher for the blessing-ledger review viewer.
# Three verbs — Start (background, no browser), Start + open in Chrome, and the loops
# API Postman console (:7070). The badge ✦ is green when the viewer is live, grey when down.
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
postman="$HOME/.dotfiles/scripts/loops-postman"
spec="$repo/public/openapi.json"   # local spec → unreleased endpoints too
pmport=7070; pmbase="http://127.0.0.1:${pmport}"

poke() { open -g "swiftbar://refreshplugin?name=blessed" 2>/dev/null; }
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
  --postman)     # the API console. Warm (:7070 answers) → just focus it. Cold → fire it and return;
    # `serve` opens the browser itself from its listen callback, so nobody has to guess startup time.
    if curl -sf --max-time 1 "$pmbase" >/dev/null 2>&1; then
      open "$pmbase"
    else
      ( nohup "$postman" serve --spec "$spec" >/dev/null 2>&1 </dev/null & )
    fi
    poke; exit 0 ;;
esac

# --- render the menu -----------------------------------------------------------------
up=0; curl -sf --max-time 1 "$base/sig" >/dev/null 2>&1 && up=1

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
echo "⚡ Postman console · :${pmport} | bash=\"$self\" param1=--postman terminal=false"
echo "---"
echo "Refresh | refresh=true"
