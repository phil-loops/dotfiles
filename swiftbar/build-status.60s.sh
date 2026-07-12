#!/usr/bin/env bash
# SwiftBar plugin — build-status: shows in-progress build-and-test MAIN image builds AND
# my own dispatched deploy-v2 runs (`task release:staging|production VERSION=…`) in the
# menu bar. Badge 🔨×N while building, +🚀 while one of my deploys is in flight, plain 🔨
# when idle (matching prwatch's 👁 grammar; SwiftBar renders an empty title as a [?]
# placeholder, so true hiding isn't an option). Complements build-notify / the prwatch
# sweep (which fire the completion desktop notifications); this is the in-flight glance.
#
# <bitbar.title>main build status</bitbar.title>
# <bitbar.desc>In-progress build-and-test main image builds (loops).</bitbar.desc>
# <bitbar.author>phil</bitbar.author>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
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

badge="🔨"
[ "$n" -gt 0 ] && badge="🔨×$n"
[ "$d" -gt 0 ] && badge="$badge 🚀"
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
# delegates to the prwatch plugin's prompt: dialog → detached prwatch → notify on done/failed
echo "➕ Watch a PR or run… | bash=\"$HOME/.dotfiles/swiftbar/prwatch.sh\" param1=--prompt terminal=false refresh=true"
echo "Actions ↗ | href=https://github.com/$REPO/actions/workflows/build-and-test.yml"
echo "Refresh | refresh=true"
