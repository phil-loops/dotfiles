#!/usr/bin/env bash
# SwiftBar plugin — build-status: shows in-progress build-and-test image builds (main +
# my own branch builds) and my dispatched deploy-v2 runs (`task release:staging|production VERSION=…`).
# Badge is ONE template SF symbol (+ count), most-urgent state:
# paperplane deploy > hammer.fill building > hammer idle (SwiftBar renders an empty
# title as a [?] placeholder, so true hiding isn't an option). Menu grammar: named
# sections (IN FLIGHT); status rows carry an SF symbol, action rows are bare
# sentence-case verbs — the icon/no-icon split IS the status/action distinction.
#
# No refreshOnOpen: the gh calls take seconds, and refreshOnOpen blocks the menu on
# them. The 60s poll keeps it fresh; opening the menu shows the last render.
#
# <bitbar.title>main build status</bitbar.title>
# <bitbar.desc>In-progress build-and-test image builds (loops) + my deploys.</bitbar.desc>
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

me="${BUILD_STATUS_USER:-$(gh api user -q .login 2>/dev/null || true)}"

rows=$(gh run list -R "$REPO" --workflow=build-and-test.yml --branch main --status in_progress -L 5 \
  --json number,headBranch,startedAt,url \
  -q '.[] | [.number,.headBranch,.startedAt,.url] | @tsv' 2>/dev/null || true)
n=0; [ -n "$rows" ] && n=$(printf '%s\n' "$rows" | grep -c .)

# my in-flight branch builds — the image build I'm actually waiting on is usually a PR
# branch, not main (main is covered above regardless of who triggered it)
mine=""
if [ -n "$me" ]; then
  mine=$(gh run list -R "$REPO" --workflow=build-and-test.yml --user "$me" --status in_progress -L 5 \
    --json number,headBranch,startedAt,url \
    -q '.[] | select(.headBranch != "main") | [.number,.headBranch,.startedAt,.url] | @tsv' 2>/dev/null || true)
fi
m=0; [ -n "$mine" ] && m=$(printf '%s\n' "$mine" | grep -c .)
b=$(( n + m ))

# my dispatched deploys (queued or running) — the "waiting on my staging deploy" case
deploys=""
if [ -n "$me" ]; then
  deploys=$(gh run list -R "$REPO" --workflow=deploy-v2.yml --user "$me" -L 10 \
    --json status,displayTitle,startedAt,url \
    -q '.[] | select(.status != "completed") | [.displayTitle,.startedAt,.url] | @tsv' 2>/dev/null || true)
fi
d=0; [ -n "$deploys" ] && d=$(printf '%s\n' "$deploys" | grep -c .)

deploy_title() {  # gh displayTitle "[staging] deploying 2026.07.13-20248-1" → "2026.07.13-20248-1 to staging"
  printf '%s' "$1" | sed -E 's/^\[([a-z-]+)\] +deploying +(.+)$/\2 to \1/'
}

# ONE template symbol in the menu bar, always — stacking glyphs reads as separate
# menu-bar items, and emoji reads as a Slack reaction among the native extras.
# Overlapping states show the most urgent (deploy > build > idle); the menu below
# lists everything regardless.
if   [ "$d" -gt 1 ]; then badge=":paperplane.fill: $d"
elif [ "$d" -gt 0 ]; then badge=":paperplane.fill:"
elif [ "$b" -gt 1 ]; then badge=":hammer.fill: $b"
elif [ "$b" -gt 0 ]; then badge=":hammer.fill:"
else badge=":hammer:"
fi
echo "$badge"
echo "---"
echo "IN FLIGHT | color=gray size=11"
if [ "$b" -eq 0 ] && [ "$d" -eq 0 ]; then
  echo "Nothing building or deploying | color=gray"
fi
if [ "$n" -gt 0 ]; then
  while IFS=$'\t' read -r num br st url; do
    [ -n "$num" ] || continue
    echo ":hammer.fill: Building ${br}-${num}-1 · $(elapsed "$st") | href=$url"
  done <<< "$rows"
fi
if [ "$m" -gt 0 ]; then
  while IFS=$'\t' read -r num br st url; do
    [ -n "$num" ] || continue
    echo ":hammer.fill: Building ${br}-${num}-1 · $(elapsed "$st") | href=$url"
  done <<< "$mine"
fi
if [ "$d" -gt 0 ]; then
  while IFS=$'\t' read -r title st url; do
    [ -n "$title" ] || continue
    echo ":paperplane.fill: Deploying $(deploy_title "$title") · $(elapsed "$st") | href=$url"
  done <<< "$deploys"
fi
echo "---"
echo "Open GitHub Actions | href=https://github.com/$REPO/actions/workflows/build-and-test.yml"
echo "Refresh | refresh=true"
