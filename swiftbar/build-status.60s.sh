#!/usr/bin/env bash
# SwiftBar plugin — build-status: shows in-progress build-and-test MAIN image builds in the
# menu bar. Badge 🔨×N while building, hidden when idle. Complements build-notify (which
# fires the completion desktop notification); this is the "is an image building right now" glance.
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
  local s now; s=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null) || { echo "?"; return; }
  now=$(date +%s); echo "$(( (now - s) / 60 ))m"
}

rows=$(gh run list -R "$REPO" --workflow=build-and-test.yml --branch main --status in_progress -L 5 \
  --json number,headBranch,startedAt,url \
  -q '.[] | [.number,.headBranch,.startedAt,.url] | @tsv' 2>/dev/null || true)

n=0; [ -n "$rows" ] && n=$(printf '%s\n' "$rows" | grep -c .)

if [ "$n" -eq 0 ]; then
  echo ""                       # idle → hidden menu-bar item
  echo "---"
  echo "no main build in progress | color=gray"
else
  echo "🔨×$n"                  # menu-bar badge
  echo "---"
  while IFS=$'\t' read -r num br st url; do
    [ -n "$num" ] || continue
    echo "${br}-${num}-1 · building $(elapsed "$st") | href=$url"
  done <<< "$rows"
fi
echo "---"
echo "Actions ↗ | href=https://github.com/$REPO/actions/workflows/build-and-test.yml"
echo "Refresh | refresh=true"
