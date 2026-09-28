#!/bin/sh
# Keeps /gen/ports.alloy — an Alloy module that tags each log source with the port its server
# listens on (server → 3000, preview:<name> → the PORT in /tmp/loops-preview-<name>.meta) —
# in step with whichever previews exist. Alloy's import.file picks up each rewrite.
out=/gen/ports.alloy
while :; do
  {
    echo 'declare "ports" {'
    echo '  argument "targets" {}'
    echo '  discovery.relabel "tagged" {'
    echo '    targets = argument.targets.value'
    echo '    rule {'
    echo '      source_labels = ["source"]'
    echo '      regex         = "server"'
    echo '      target_label  = "port"'
    echo '      replacement   = "3000"'
    echo '    }'
    # A dead preview leaves its .meta behind, so one port can be claimed twice — the newest
    # STARTED owns it.
    for m in /hostlogs/loops-preview-*.meta; do
      [ -f "$m" ] || continue
      name="${m#/hostlogs/loops-preview-}"; name="${name%.meta}"
      echo "$(sed -n 's/^STARTED=//p' "$m") $name $(sed -n 's/^PORT=//p' "$m")"
    done | sort -rn | awk 'NF == 3 && !seen[$3]++ { print $2, $3 }' | while read -r name port; do
      echo '    rule {'
      echo '      source_labels = ["source"]'
      echo "      regex         = \"preview:$name(-jobs)?\""
      echo '      target_label  = "port"'
      echo "      replacement   = \"$port\""
      echo '    }'
    done
    echo '  }'
    echo '  export "output" {'
    echo '    value = discovery.relabel.tagged.output'
    echo '  }'
    echo '}'
  } > "$out.tmp"
  cmp -s "$out.tmp" "$out" 2>/dev/null && rm -f "$out.tmp" || mv "$out.tmp" "$out"
  sleep 5
done
