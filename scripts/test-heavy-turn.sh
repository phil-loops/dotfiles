#!/usr/bin/env bash
# test-heavy-turn.sh — harness for scripts/heavy-turn on a private queue dir.
# Asserts: the slot budget caps concurrency, class caps hold, a killed holder is reaped,
# interactive waiters go before batch ones, nested calls pass straight through,
# --acquire/--release hold a slot for another pid, memory pressure shrinks the budget to one,
# every finished ticket lands in the journal, and a granted command runs niced.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HT="$SCRIPTS_DIR/heavy-turn"
[[ -x "$HT" ]] || { echo "missing: $HT" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/heavy-turn-test.XXXXXX")"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT
export HEAVY_TURN_DIR="$WORK/q"
export HEAVY_TURN_JOURNAL="$WORK/journal.tsv"
export HEAVY_TURN_MEM_LEVEL=90
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

# 10. memory pressure shrinks the budget to one slot; a waiter is told why
L="$WORK/mem"
for i in 1 2 3 4; do HEAVY_TURN_SLOTS=2 HEAVY_TURN_MEM_LEVEL=10 "$HT" -- "$WORK/job" "$L" "m$i" 0.3 2>/dev/null & done
wait
assert_eq "memory pressure serializes the budget" 1 "$(cat "$L.peak")"
assert_eq "all four still ran under pressure" 4 "$(wc -l < "$L.order" | tr -d ' ')"
HEAVY_TURN_SLOTS=2 HEAVY_TURN_MEM_LEVEL=10 "$HT" -- sleep 1 2>/dev/null &
sleep 0.3
msg=$(HEAVY_TURN_SLOTS=2 HEAVY_TURN_MEM_LEVEL=10 "$HT" -- true 2>&1 >/dev/null)
wait
[[ "$msg" == *"(1/1 held, memory 10% < 30%: budget 1)"* ]] \
  && ok "waiter names the memory pressure" || bad "waiter names the memory pressure" "$msg"
st=$(HEAVY_TURN_SLOTS=2 HEAVY_TURN_MEM_LEVEL=10 "$HT" --status)
[[ "$st" == *"0/1 slots held"*"budget 1"* ]] && ok "status shows the shrunk budget" || bad "status shows the shrunk budget" "$st"

# 11. every finished ticket lands in the journal: class, wait, run, exit, command
HEAVY_TURN_SLOTS=1 "$HT" --class probe -- sh -c 'sleep 0.2; exit 3' 2>/dev/null
last=$(tail -1 "$HEAVY_TURN_JOURNAL")
IFS=$'\t' read -r when cls pid waits runs status mem cwd cmd <<< "$last"
assert_eq "journal: class" probe "$cls"
assert_eq "journal: exit status" 3 "$status"
assert_eq "journal: mem level at grant" 90 "$mem"
assert_eq "journal: command" "sh -c sleep 0.2; exit 3" "$cmd"
[[ "$cwd" == "$PWD" ]] && ok "journal: cwd" || bad "journal: cwd" "$cwd"
n=$(wc -l < "$HEAVY_TURN_JOURNAL" | tr -d ' ')
(( n >= 25 )) && ok "journal: every earlier ticket was recorded ($n lines)" || bad "journal: every earlier ticket was recorded" "$n lines"

# 12. the lock is reentrant: a signal handler's drop() inside a held lock must not wait on itself
out=$(python3 - "$HT" <<'PY' 2>&1
import runpy, signal, sys
signal.alarm(5)   # a self-deadlock dies here instead of hanging the suite
g = runpy.run_path(sys.argv[1], run_name="heavy_turn")
with g["locked"]():
    with g["locked"]():
        pass
    with g["locked"]():
        pass
with g["locked"]():
    print("reentrant")
PY
)
assert_eq "a nested lock returns instead of waiting on itself" reentrant "$out"
# …and a SIGTERMed waiter leaves the queue usable
HEAVY_TURN_SLOTS=1 "$HT" -- sleep 2 2>/dev/null &
sleep 0.3
HEAVY_TURN_SLOTS=1 "$HT" --batch -- true 2>/dev/null & w=$!
sleep 0.3
for _ in 1 2 3 4 5; do kill -TERM $w 2>/dev/null; done
wait $w 2>/dev/null
st=$(HEAVY_TURN_SLOTS=1 "$HT" --status 2>&1)
[[ "$st" == *"slots held"* && "$st" != *"waiting  "* ]] && ok "a killed waiter drops its ticket" || bad "a killed waiter drops its ticket" "$st"
wait

# 13. a slot is for work that will change something
# --unless: a satisfied probe ends the request before it queues, and the command never runs
rm -f "$WORK/ran"
HEAVY_TURN_SLOTS=1 "$HT" --class need --unless "true" -- touch "$WORK/ran" 2>/dev/null
[[ ! -e "$WORK/ran" ]] && ok "--unless: done work is not run" || bad "--unless: done work is not run" "ran"
assert_eq "--unless: journaled unneeded" unneeded "$(tail -1 "$HEAVY_TURN_JOURNAL" | cut -f6)"
HEAVY_TURN_SLOTS=1 "$HT" --class need --unless "false" -- touch "$WORK/ran" 2>/dev/null
[[ -e "$WORK/ran" ]] && ok "--unless: needed work runs" || bad "--unless: needed work runs" "did not run"
# …and the probe is asked again at the grant: work someone else did while this waited is skipped
rm -f "$WORK/ran" "$WORK/done"
HEAVY_TURN_SLOTS=1 "$HT" -- sh -c "sleep 1; touch '$WORK/done'" 2>/dev/null &
sleep 0.3
HEAVY_TURN_SLOTS=1 "$HT" --class need --unless "test -e '$WORK/done'" -- touch "$WORK/ran" 2>/dev/null
wait
[[ ! -e "$WORK/ran" ]] && ok "--unless: work done while waiting is not repeated" || bad "--unless: work done while waiting is not repeated" "ran"
assert_eq "--unless: the grant-time skip is journaled unneeded" unneeded "$(grep "$(printf '\tneed\t')" "$HEAVY_TURN_JOURNAL" | tail -1 | cut -f6)"
# --key: five requests for the same waiting work are one ticket
: > "$WORK/keyed"
HEAVY_TURN_SLOTS=1 "$HT" -- sleep 1.5 2>/dev/null &
sleep 0.3
for _ in 1 2 3 4 5; do
  HEAVY_TURN_SLOTS=1 "$HT" --class fold --key same -- sh -c "echo x >> '$WORK/keyed'" 2>/dev/null &
  sleep 0.1
done
HEAVY_TURN_SLOTS=1 "$HT" --class fold --key other -- sh -c "echo y >> '$WORK/keyed'" 2>/dev/null &
sleep 0.2
st=$(HEAVY_TURN_SLOTS=1 "$HT" --status)
assert_eq "--key: one waiting ticket per key" 2 "$(grep -c 'waiting  fold' <<< "$st")"
wait
assert_eq "--key: the folded work ran once per key" "x y" "$(sort "$WORK/keyed" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "--key: four folds journaled" 4 "$(cut -f2,6 "$HEAVY_TURN_JOURNAL" | grep -c "$(printf 'fold\tfolded')")"
# …and a key only folds into WAITING work: a running holder has read its inputs already
HEAVY_TURN_SLOTS=2 "$HT" --class fold --key live -- sleep 1 2>/dev/null &
sleep 0.3
rm -f "$WORK/ran"
HEAVY_TURN_SLOTS=2 "$HT" --class fold --key live -- touch "$WORK/ran" 2>/dev/null
wait
[[ -e "$WORK/ran" ]] && ok "--key: a request behind a RUNNING twin still runs" || bad "--key: a request behind a RUNNING twin still runs" "folded"

# 14. a slot is for bounded work: a holder past the bound stops counting against the budget
HEAVY_TURN_SLOTS=1 HEAVY_TURN_MAX_HOLD=0.5 "$HT" --class long -- sleep 3 2>/dev/null &
sleep 0.2
st=$(HEAVY_TURN_SLOTS=1 HEAVY_TURN_MAX_HOLD=0.5 "$HT" --status)
[[ "$st" == *"1/1 slots held"* ]] && ok "bound: a holder inside the bound counts" || bad "bound: a holder inside the bound counts" "$st"
sleep 0.6
t0=$(python3 -c 'import time;print(time.time())')
HEAVY_TURN_SLOTS=1 HEAVY_TURN_MAX_HOLD=0.5 "$HT" -- true 2>/dev/null
el=$(python3 -c "import time;print(int((time.time()-$t0)*10))")
(( el < 15 )) && ok "bound: work is admitted past an overstayed holder" || bad "bound: work is admitted past an overstayed holder" "waited ${el}00ms"
st=$(HEAVY_TURN_SLOTS=1 HEAVY_TURN_MAX_HOLD=0.5 "$HT" --status)
[[ "$st" == *"0/1 slots held"*"OVERSTAYED"* ]] && ok "bound: status names the overstayer" || bad "bound: status names the overstayer" "$st"
# …but it keeps its class cap, so a second unbounded job of the class does not start beside it
HEAVY_TURN_SLOTS=2 HEAVY_TURN_MAX_HOLD=0.5 HEAVY_TURN_CAP_LONG=1 "$HT" --class long -- touch "$WORK/second-long" 2>/dev/null &
sleep 0.5
[[ ! -e "$WORK/second-long" ]] && ok "bound: an overstayer still holds its class cap" || bad "bound: an overstayer still holds its class cap" "second ran"
wait

# 15. a granted command runs niced (default 10), and HEAVY_TURN_NICE=0 leaves it at the caller's
base=$(ps -o nice= -p $$ | tr -d ' ')
assert_eq "granted command runs at nice +10" "$((base + 10))" "$("$HT" -- sh -c 'ps -o nice= -p $$' | tr -d ' ')"
assert_eq "HEAVY_TURN_NICE=0 keeps the caller's priority" "$base" "$(HEAVY_TURN_NICE=0 "$HT" -- sh -c 'ps -o nice= -p $$' | tr -d ' ')"
assert_eq "an unreadable HEAVY_TURN_NICE falls back to +10" "$((base + 10))" "$(HEAVY_TURN_NICE=abc "$HT" -- sh -c 'ps -o nice= -p $$' | tr -d ' ')"
assert_eq "a negative HEAVY_TURN_NICE runs at the caller's priority" "$base" "$(HEAVY_TURN_NICE=-5 "$HT" -- sh -c 'ps -o nice= -p $$' | tr -d ' ')"

# 16. the audit names a class that breaks either rule
aj="$WORK/audit.tsv"; day=2020-01-01
for i in $(seq 1 12); do printf '%sT00:00:%02d\tnoop batch\t1\t5\t1\t0\t90\t/\tx\n' $day $i; done > "$aj"
printf '%sT01:00:00\tforever\t1\t0\t4000\t0\t90\t/\tx\n' $day >> "$aj"
printf '%sT02:00:00\tfine\t1\t0\t30\t0\t90\t/\tx\n' $day >> "$aj"
out=$(HEAVY_TURN_JOURNAL="$aj" "$HT" --audit $day); rc=$?
assert_eq "audit: exits 1 on a broken rule" 1 "$rc"
[[ "$out" == *"✗ noop batch: 12 of 12"* ]] && ok "audit: names the class asking for slots it does not need" || bad "audit: names the no-op class" "$out"
[[ "$out" == *"✗ forever: 1 run(s) held a slot past"* ]] && ok "audit: names the unbounded class" || bad "audit: names the unbounded class" "$out"
printf '%sT02:00:00\tfine\t1\t0\t30\t0\t90\t/\tx\n' $day > "$aj"
HEAVY_TURN_JOURNAL="$aj" "$HT" --audit $day >/dev/null; assert_eq "audit: exits 0 on a clean day" 0 "$?"

echo "---- $PASS passed, $FAIL failed"
(( FAIL == 0 ))
