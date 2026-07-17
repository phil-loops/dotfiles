#!/usr/bin/env bash
# SwiftBar plugin — build-status: shows in-progress build-and-test MAIN image builds,
# my own dispatched deploy-v2 runs (`task release:staging|production VERSION=…`),
# active prwatch watches (~/.cache/prwatch/tracking), and unacknowledged sticky
# completions (~/.cache/prwatch/done — prwatch notify_sticky). Badge is ONE template
# SF symbol (+ count), most-urgent state: checkmark unacked done > paperplane deploy >
# hammer.fill building > eye watching > hammer idle (SwiftBar renders an empty title
# as a [?] placeholder, so true hiding isn't an option). Menu grammar: named sections
# (IN FLIGHT / FINISHED / WATCHING); status rows carry an SF symbol, action rows are
# bare sentence-case verbs — the icon/no-icon split IS the status/action distinction.
# Complements build-notify / the prwatch sweep (which fire the completion desktop
# notifications); this is the in-flight glance + the can't-miss-it residue.
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
donedir="$HOME/.cache/prwatch/done"

# click actions: acknowledge sticky ✅ completions (prwatch notify_sticky writes them)
if [ "${1:-}" = "--ack" ]; then
  rm -f "$donedir/$2.tsv"
  open -g "swiftbar://refreshplugin?name=build-status" 2>/dev/null; exit 0
fi
if [ "${1:-}" = "--ack-all" ]; then
  rm -f "$donedir"/*.tsv
  open -g "swiftbar://refreshplugin?name=build-status" 2>/dev/null; exit 0
fi

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

# unacknowledged sticky completions (deploy landed / explicit watch finished).
# Rows expire after BUILD_STATUS_DONE_TTL_HOURS (default 48) — this is a catch-up
# ledger for a glance away, not an archive; days-old deploys are just noise.
ttl_s=$(( ${BUILD_STATUS_DONE_TTL_HOURS:-48} * 3600 )); now=$(date +%s)
dones=""
for f in "$donedir"/*.tsv; do
  [ -e "$f" ] || continue
  IFS=$'\t' read -r dst dmsg durl dts < "$f"
  case "$dts" in *[!0-9]*|"") dts=$(stat -f %m "$f" 2>/dev/null || echo "$now") ;; esac
  [ $(( now - dts )) -gt "$ttl_s" ] && { rm -f "$f"; continue; }
  dones="${dones}$(basename "$f" .tsv)"$'\t'"$dst"$'\t'"$dmsg"$'\t'"$durl"$'\n'
done
k=0; [ -n "$dones" ] && k=$(printf '%s' "$dones" | grep -c .)

deploy_title() {  # gh displayTitle "[staging] deploying 2026.07.13-20248-1" → "2026.07.13-20248-1 to staging"
  printf '%s' "$1" | sed -E 's/^\[([a-z-]+)\] +deploying +(.+)$/\2 to \1/'
}

# ONE template symbol in the menu bar, always — stacking glyphs reads as separate
# menu-bar items, and emoji reads as a Slack reaction among the native extras.
# Overlapping states show the most urgent (unacked done > deploy > main build >
# watches > idle); the menu below lists everything regardless.
if   [ "$k" -gt 1 ]; then badge=":checkmark.circle.fill: $k"
elif [ "$k" -gt 0 ]; then badge=":checkmark.circle.fill:"
elif [ "$d" -gt 1 ]; then badge=":paperplane.fill: $d"
elif [ "$d" -gt 0 ]; then badge=":paperplane.fill:"
elif [ "$n" -gt 1 ]; then badge=":hammer.fill: $n"
elif [ "$n" -gt 0 ]; then badge=":hammer.fill:"
elif [ "$w" -gt 0 ]; then badge=":eye: $w"
else badge=":hammer:"
fi
echo "$badge"
echo "---"
echo "IN FLIGHT | color=gray size=11"
if [ "$n" -eq 0 ] && [ "$d" -eq 0 ]; then
  echo "Nothing building or deploying | color=gray"
fi
if [ "$n" -gt 0 ]; then
  while IFS=$'\t' read -r num br st url; do
    [ -n "$num" ] || continue
    echo ":hammer.fill: Building ${br}-${num}-1 · $(elapsed "$st") | href=$url"
  done <<< "$rows"
fi
if [ "$d" -gt 0 ]; then
  while IFS=$'\t' read -r title st url; do
    [ -n "$title" ] || continue
    echo ":paperplane.fill: Deploying $(deploy_title "$title") · $(elapsed "$st") | href=$url"
  done <<< "$deploys"
fi
# staging staleness — ground truth is build-notify's buildId probe (staging-last: version,
# actor, flip-epoch; staging-pending: an enqueue whose buildId flip hasn't been seen yet).
# Rolling-out is the "would have checked Slack" state; live-age answers "how stale is staging".
bn="$HOME/.cache/build-notify"
staging_url="${BUILD_NOTIFY_STAGING_URL:-https://app.l3s.email/}"
staging_line=""
if [ -s "$bn/staging-pending" ]; then
  IFS=$'\t' read -r _ parm_s _ pver pactor purl < "$bn/staging-pending"
  am=$(( ($(date +%s) - ${parm_s:-0}) / 60 ))
  staging_line=":ferry.fill: Staging: ${pver} (${pactor}) rolling out · ${am}m | href=${purl:-$staging_url}"
elif [ -s "$bn/staging-last" ]; then
  IFS=$'\t' read -r sver sactor sflip < "$bn/staging-last"
  sm=$(( ($(date +%s) - ${sflip:-0}) / 60 ))
  age="${sm}m"; [ "$sm" -ge 60 ] && age="$(( sm / 60 ))h $(( sm % 60 ))m"
  if [ "$sver" = "?" ]; then
    staging_line=":ferry: Staging flipped ${age} ago (untracked deploy) | href=$staging_url"
  else
    staging_line=":ferry: Staging: ${sver} (${sactor}) · live ${age} | href=$staging_url"
  fi
fi
if [ -n "$staging_line" ]; then
  echo "---"
  echo "STAGING | color=gray size=11"
  echo "$staging_line"
fi
if [ "$k" -gt 0 ]; then
  echo "---"
  echo "FINISHED | color=gray size=11"
  while IFS=$'\t' read -r key dst dmsg durl; do
    [ -n "$key" ] || continue
    # dst picks the symbol only; the message carries the words (legacy rows still
    # hold glyph-prefixed dst strings — match on the failure words, not the glyph)
    case "$dst" in
      *fail*|*✗*|*cancel*|*timed_out*) ic=":xmark.circle.fill:" ;;
      *) ic=":checkmark.circle.fill:" ;;
    esac
    echo "${ic} ${dmsg} | href=${durl}"
    echo "-- Dismiss | bash=\"$0\" param1=--ack param2=${key} terminal=false"
  done <<< "$dones"
  if [ "$k" -gt 1 ]; then
    echo "Clear all | bash=\"$0\" param1=--ack-all terminal=false"
  fi
fi
if [ "$w" -gt 0 ]; then
  echo "---"
  echo "WATCHING | color=gray size=11"
  while IFS=$'\t' read -r key wrepo wid wtitle wurl; do
    [ -n "$key" ] || continue
    echo ":eye: ${wrepo}#${wid} — ${wtitle} | href=${wurl}"
    echo "-- Stop watching | bash=\"$HOME/.dotfiles/swiftbar/prwatch.sh\" param1=--stop param2=${key} terminal=false"
  done <<< "$watches"
fi
echo "---"
# delegates to the prwatch plugin's prompt: dialog → detached prwatch → notify on done/failed
echo "Watch a PR or run… | bash=\"$HOME/.dotfiles/swiftbar/prwatch.sh\" param1=--prompt terminal=false"
echo "Open GitHub Actions | href=https://github.com/$REPO/actions/workflows/build-and-test.yml"
echo "Refresh | refresh=true"
