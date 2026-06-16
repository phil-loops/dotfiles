#!/bin/zsh
# SwiftBar plugin — show which PRs prwatch is watching right now.
#
# <bitbar.title>prwatch tracking</bitbar.title>
# <bitbar.desc>PRs whose CI prwatch is actively watching (no polling — reads the live --await registry).</bitbar.desc>
# <bitbar.author>phil</bitbar.author>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
#
# The filename carries NO refresh interval, so SwiftBar never polls it — it
# refreshes on open and whenever a watcher pokes swiftbar://refreshplugin?name=prwatch.
# Install: brew install --cask swiftbar, point its plugin folder here, symlink this in.

trackdir="$HOME/.cache/prwatch/tracking"

rows=()
for f in "$trackdir"/*.tsv(N); do
  IFS=$'\t' read -r repo num title branch started pid <"$f"
  kill -0 "$pid" 2>/dev/null || { rm -f "$f"; continue }   # watcher gone → prune
  rows+=("$repo"$'\t'"$num"$'\t'"$title"$'\t'"$branch")
done

n=${#rows}
if (( n )); then echo "👁 $n"; else echo "👁"; fi   # menu-bar badge
echo "---"

if (( n == 0 )); then
  echo "No PRs being watched | color=gray"
else
  for r in "${rows[@]}"; do
    IFS=$'\t' read -r repo num title branch <<<"$r"
    echo "${repo}#${num} — ${title} | href=https://github.com/${repo}/pull/${num}"
    echo "${branch} | size=11 color=gray href=https://github.com/${repo}/pull/${num}"
  done
fi

echo "---"
echo "Refresh | refresh=true"
