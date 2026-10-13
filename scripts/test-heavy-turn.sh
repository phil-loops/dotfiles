#!/usr/bin/env bash
# test-heavy-turn.sh — harness for scripts/heavy-turn on a private queue dir.
# Asserts: the slot budget caps concurrency, class caps hold, a killed holder is reaped,
# interactive waiters go before batch ones, nested calls pass straight through, and
# --acquire/--release hold a slot for another pid.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HT="$SCRIPTS_DIR/heavy-turn"
[[ -x "$HT" ]] || { echo "missing: $HT" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/heavy-turn-test.XXXXXX")"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT
export HEAVY_TURN_DIR="$WORK/q"
unset HEAVY_TURN_HELD
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL  $1: $2"; }
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

# a job that records its own concurrency: +1 on start, peak tracked, -1 on exit
cat > "$WORK/job" <<'EOF'
#!/usr/bin/env python3
import fcntl, sys, time
log, tag, dur = sys.argv[1], sys.argv[2], float(sys.argv[3])
def bump(d):
    with open(log + ".lock", "a") as l:
        fcntl.flock(l, fcntl.LOCK_EX)
        try: n = int(open(log + ".n").read())
        except OSError: n = 0
        n += d; open(log + ".n", "w").write(str(n))
        if d > 0:
            try: p = int(open(log + ".peak").read())
            except OSError: p = 0
            if n > p: open(log + ".peak", "w").write(str(n))
            open(log + ".order", "a").write(tag + "\n")
bump(1); time.sleep(dur); bump(-1)
EOF
chmod +x "$WORK/job"
timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }

# 1. budget: 6 jobs, 2 slots → peak concurrency 2
L="$WORK/budget"
for i in 1 2 3 4 5 6; do HEAVY_TURN_SLOTS=2 "$HT" -- "$WORK/job" "$L" "j$i" 0.6 2>/dev/null & done
wait
assert_eq "budget caps concurrency at 2" 2 "$(cat "$L.peak")"
assert_eq "all six ran" 6 "$(wc -l < "$L.order" | tr -d ' ')"

# 2. class cap: 4 'gates' jobs with 3 slots → peak 1
L="$WORK/cap"
for i in 1 2 3 4; do HEAVY_TURN_SLOTS=3 "$HT" --class gates -- "$WORK/job" "$L" "g$i" 0.4 2>/dev/null & done
wait
assert_eq "class cap holds gates to 1" 1 "$(cat "$L.peak")"

# 3. a class at its cap doesn't block another class behind it
L="$WORK/hol"
HEAVY_TURN_SLOTS=2 "$HT" --class gates -- "$WORK/job" "$L" g1 1.2 2>/dev/null &
sleep 0.3
HEAVY_TURN_SLOTS=2 "$HT" --class gates -- "$WORK/job" "$L" g2 0.2 2>/dev/null &
sleep 0.3
HEAVY_TURN_SLOTS=2 "$HT" --class tsc -- "$WORK/job" "$L" t1 0.2 2>/dev/null &
wait
assert_eq "tsc overtakes a cap-blocked gates waiter" "g1 t1 g2" "$(tr '\n' ' ' < "$L.order" | sed 's/ $//')"

# 4. killed holder is reaped: SIGKILL the heavy-turn process holding the only slot
L="$WORK/reap"
HEAVY_TURN_SLOTS=1 "$HT" -- sleep 30 2>/dev/null &
holder=$!
sleep 0.5
kid=$(pgrep -P "$holder"); kill -9 "$holder"; [[ -n "$kid" ]] && kill "$kid" 2>/dev/null
t0=$(date +%s)
HEAVY_TURN_SLOTS=1 "$HT" -- "$WORK/job" "$L" after 0.1 2>/dev/null
assert_eq "dead holder reaped, next caller ran" "after" "$(cat "$L.order")"
(( $(date +%s) - t0 < 5 )) && ok "reap is prompt" || bad "reap is prompt" "took $(( $(date +%s) - t0 ))s"

# 5. priority: with the slot busy, a batch waiter queued FIRST still runs after interactive ones
L="$WORK/prio"
HEAVY_TURN_SLOTS=1 "$HT" -- "$WORK/job" "$L" busy 1.0 2>/dev/null &
sleep 0.3
HEAVY_TURN_SLOTS=1 "$HT" --batch -- "$WORK/job" "$L" batch 0.1 2>/dev/null &
sleep 0.3
HEAVY_TURN_SLOTS=1 "$HT" -- "$WORK/job" "$L" inter1 0.1 2>/dev/null &
sleep 0.1
HEAVY_TURN_SLOTS=1 "$HT" -- "$WORK/job" "$L" inter2 0.1 2>/dev/null &
wait
assert_eq "interactive before batch, FIFO within" "busy inter1 inter2 batch" "$(tr '\n' ' ' < "$L.order" | sed 's/ $//')"

# 6. nested call inside a held slot passes straight through (no self-deadlock at 1 slot)
out=$(HEAVY_TURN_SLOTS=1 timeout 10 "$HT" -- "$HT" -- echo nested-ran 2>/dev/null)
assert_eq "nested heavy-turn runs through" "nested-ran" "$out"

# 7. acquire/release on behalf of another pid; the owner dying frees it too
sleep 60 & owner=$!
tid=$(HEAVY_TURN_SLOTS=1 "$HT" --acquire --class preview --owner "$owner" 2>/dev/null)
[[ -n "$tid" ]] && ok "acquire printed a ticket" || bad "acquire printed a ticket" "empty"
held=$(HEAVY_TURN_SLOTS=1 "$HT" --status --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["held"]))')
assert_eq "status shows the held slot" 1 "$held"
"$HT" --release "$tid"
held=$(HEAVY_TURN_SLOTS=1 "$HT" --status --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["held"]))')
assert_eq "release frees it" 0 "$held"
HEAVY_TURN_SLOTS=1 "$HT" --acquire --owner "$owner" >/dev/null 2>&1
kill "$owner"; wait "$owner" 2>/dev/null
out=$(HEAVY_TURN_SLOTS=1 timeout 5 "$HT" -- echo after-owner-died 2>/dev/null)
assert_eq "dead owner's held slot is reaped" "after-owner-died" "$out"

# 8. a waiting caller says why
HEAVY_TURN_SLOTS=1 "$HT" -- sleep 1 2>/dev/null &
sleep 0.3
msg=$(HEAVY_TURN_SLOTS=1 "$HT" -- true 2>&1 >/dev/null)
wait
[[ "$msg" == *"waiting for a slot (1/1 held"* && "$msg" == *"held: default pid"* ]] \
  && ok "waiter names the holder" || bad "waiter names the holder" "$msg"

# 9. exit status passes through; tsc-turn alias routes through the queue
HEAVY_TURN_SLOTS=1 "$HT" -- sh -c 'exit 7'; assert_eq "exit code passes through" 7 "$?"
out=$("$SCRIPTS_DIR/tsc-turn" sh -c 'echo "$HEAVY_TURN_HELD" | wc -c | tr -d " "' 2>/dev/null)
[[ "$out" -gt 1 ]] && ok "tsc-turn runs under a heavy-turn slot" || bad "tsc-turn runs under a heavy-turn slot" "$out"

echo "---- $PASS passed, $FAIL failed"
(( FAIL == 0 ))
