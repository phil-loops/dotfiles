#!/usr/bin/env bash
# SwiftBar plugin — build-status: shows in-progress build-and-test MAIN image builds,
# my own dispatched deploy-v2 runs (`task release:staging|production VERSION=…`), AND
# active prwatch watches (~/.cache/prwatch/tracking) in the menu bar. Badge 🔨×N while
# building, +🚀 while one of my deploys is in flight, +👁N while watching, plain 🔨 when
# idle (SwiftBar renders an empty title as a [?] placeholder, so true hiding isn't an
# option). Complements build-notify / the prwatch sweep (which fire the completion
# desktop notifications); this is the in-flight glance.
#
# No refreshOnOpen: the gh calls take seconds, and refreshOnOpen blocks the menu on
# them. The 60s poll + prwatch's pokes (swiftbar://refreshplugin?name=build-status on
# watch start/stop/finish) keep it fresh; opening the menu shows the last render.
#
# <bitbar.title>main build status</bitbar.title>
# <bitbar.desc>In-progress build-and-test main image builds (loops) + prwatch watches.</bitbar.desc>
# <bitbar.author>phil</bitbar.author>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"
REPO="${BUILD_STATUS_REPO:-Loops-so/loops}"

elapsed() {  # ISO startedAt -> "Nm"
  [ -n "$1" ] || { echo "?"; return; }
  # -u: startedAt is UTC (trailing Z). Without it BSD `date` parses the time as LOCAL, so
  # `now - s` came out ~7h negative (the PDT offset) — the "-414m" bug.
  local s now; s=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null) || { echo "?"; return; }
  now=$(date +%s); echo "$(( (now - s) / 60 ))m"
}

rows=$(gh run list -R "$REPO" --workflow=build-and-test.yml --branch main --status in_progress -L 5 \
  --json number,headBranch,startedAt,url \
  -q '.[] | [.number,.headBranch,.startedAt,.url] | @tsv' 2>/dev/null || true)
n=0; [ -n "$rows" ] && n=$(printf '%s\n' "$rows" | grep -c .)

# my dispatched deploys (queued or running) — the "waiting on my staging deploy" case
me="${BUILD_STATUS_USER:-$(gh api user -q .login 2>/dev/null || true)}"
deploys=""
if [ -n "$me" ]; then
  deploys=$(gh run list -R "$REPO" --workflow=deploy-v2.yml --user "$me" -L 10 \
    --json status,displayTitle,startedAt,url \
    -q '.[] | select(.status != "completed") | [.displayTitle,.startedAt,.url] | @tsv' 2>/dev/null || true)
fi
d=0; [ -n "$deploys" ] && d=$(printf '%s\n' "$deploys" | grep -c .)

# active prwatch watches — local marker files, no network; prune markers whose watcher died
trackdir="$HOME/.cache/prwatch/tracking"
watches=""
for f in "$trackdir"/*.tsv; do
  [ -e "$f" ] || continue
  IFS=$'\t' read -r wrepo wid wtitle wurl _ wpid < "$f"
  kill -0 "$wpid" 2>/dev/null || { rm -f "$f"; continue; }
  key=$(basename "$f" .tsv)
  watches="${watches}${key}"$'\t'"${wrepo}"$'\t'"${wid}"$'\t'"${wtitle}"$'\t'"${wurl}"$'\n'
done
w=0; [ -n "$watches" ] && w=$(printf '%s' "$watches" | grep -c .)

badge="🔨"
[ "$n" -gt 0 ] && badge="🔨×$n"
[ "$d" -gt 0 ] && badge="$badge 🚀"
[ "$w" -gt 0 ] && badge="$badge 👁$w"
echo "$badge"
echo "---"
if [ "$n" -eq 0 ] && [ "$d" -eq 0 ]; then
  echo "no main build or deploy in progress | color=gray"
fi
if [ "$n" -gt 0 ]; then
  while IFS=$'\t' read -r num br st url; do
    [ -n "$num" ] || continue
    echo "${br}-${num}-1 · building $(elapsed "$st") | href=$url"
  done <<< "$rows"
fi
if [ "$d" -gt 0 ]; then
  while IFS=$'\t' read -r title st url; do
    [ -n "$title" ] || continue
    echo "🚀 ${title} · $(elapsed "$st") | href=$url"
  done <<< "$deploys"
fi
echo "---"
if [ "$w" -gt 0 ]; then
  while IFS=$'\t' read -r key wrepo wid wtitle wurl; do
    [ -n "$key" ] || continue
    echo "👁 ${wrepo}#${wid} — ${wtitle} | href=${wurl}"
    echo "-- ✗ Stop watching | bash=\"$HOME/.dotfiles/swiftbar/prwatch.sh\" param1=--stop param2=${key} terminal=false"
  done <<< "$watches"
fi
# delegates to the prwatch plugin's prompt: dialog → detached prwatch → notify on done/failed
echo "➕ Watch a PR or run… | bash=\"$HOME/.dotfiles/swiftbar/prwatch.sh\" param1=--prompt terminal=false"
echo "---"
echo "Actions ↗ | href=https://github.com/$REPO/actions/workflows/build-and-test.yml"
echo "Refresh | refresh=true"
