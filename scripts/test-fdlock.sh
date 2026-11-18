#!/usr/bin/env bash
# test-fdlock.sh — the kernel lock seed-gen holds its trees with: a holder's death, SIGKILL
# included, frees the lock at once (2026-11-17: a SIGKILLed gates run stranded mkdir locks for
# 10 minutes). Runs seed-gen's own wait_lock, extracted from the script, not a copy of it.
set -u
here="$(cd "$(dirname "$0")" && pwd -P)"
FDLOCK="$here/fdlock"
T=$(mktemp -d "${TMPDIR:-/tmp}/test-fdlock.XXXXXX"); trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok(){ echo "ok   $1"; pass=$((pass + 1)); }
no(){ echo "FAIL $1"; fail=$((fail + 1)); }
now(){ python3 -c 'import time; print(time.monotonic())'; }
# a holder that takes the lock on fd 9, says so, then sleeps as its own process
hold(){ bash -c 'exec 9>>"$1"; "$2" 9 || exit 1; echo held; exec sleep 300' _ "$1" "$FDLOCK" > "$T/held.$$" & echo $!; }
wait_held(){ for _ in $(seq 100); do grep -q held "$T/held.$$" 2>/dev/null && return 0; sleep 0.05; done; return 1; }

f="$T/a.flock"; pid=$(hold "$f"); wait_held
"$FDLOCK" --held "$f" && ok "--held sees a live holder" || no "--held missed a live holder"
bash -c 'exec 9>>"$1"; "$2" 9 --wait 0.3' _ "$f" "$FDLOCK"; [ $? -eq 1 ] && ok "a contended lock times out with 1" || no "a contended lock didn't time out"
kill -9 "$pid"; wait "$pid" 2>/dev/null
t0=$(now); bash -c 'exec 9>>"$1"; "$2" 9 --wait 5' _ "$f" "$FDLOCK"; rc=$?; t1=$(now)
[ $rc -eq 0 ] && python3 -c "import sys; sys.exit(0 if $t1 - $t0 < 1 else 1)" \
  && ok "kill -9 on the holder frees the lock at once" || no "the lock outlived its SIGKILLed holder (rc $rc)"
"$FDLOCK" --held "$f" && no "--held reports a dead holder" || ok "--held is false once the holder is gone"

# a spawn that closes the fd doesn't inherit the lock; one that keeps it does (the hazard the
# seed-gen spawns close against)
g="$T/b.flock"
bash -c 'exec 9>>"$1"; "$2" 9; sleep 30 9>&- & exit 0' _ "$g" "$FDLOCK"
sleep 0.2; "$FDLOCK" --held "$g" && no "a spawn that closed fd 9 still held the lock" || ok "a spawn that closes the fd leaves the lock free"
h="$T/c.flock"
bash -c 'exec 9>>"$1"; "$2" 9; sleep 30 & echo $! > "$3"; exit 0' _ "$h" "$FDLOCK" "$T/kid"
sleep 0.2; "$FDLOCK" --held "$h" && ok "a spawn that keeps the fd keeps the lock" || no "an inheriting spawn didn't hold the lock"
kill "$(cat "$T/kid")" 2>/dev/null

# seed-gen's own wait_lock, extracted and run: the incident, end to end
eval "$(sed -n '/^FDLOCK=/,/^}/p' "$here/seed-gen" | sed "s|^FDLOCK=.*|FDLOCK=\"$FDLOCK\"|")"
type wait_lock >/dev/null 2>&1 && ok "seed-gen's wait_lock extracted" || no "couldn't extract seed-gen's wait_lock"
mkdir -p "$T/gitdir"; tl="$T/gitdir/seed-gen.flock"; pid=$(hold "$tl"); wait_held
kill -9 "$pid"; wait "$pid" 2>/dev/null
t0=$(now); ( wait_lock "$tl" 9 ); rc=$?; t1=$(now)
[ $rc -eq 0 ] && python3 -c "import sys; sys.exit(0 if $t1 - $t0 < 1 else 1)" \
  && ok "seed-gen takes a tree whose locker was SIGKILLed at once (was: 600 s)" || no "seed-gen waited on a dead locker (rc $rc)"
( wait_lock "$T/gone/x.flock" 9 ); [ $? -eq 1 ] && ok "a lock whose home vanished fails, never spins" || no "a vanished home didn't fail"
grep -qE 'stat -f %m "\$lock"|age > 600|mkdir "\$lock"' "$here/seed-gen" && no "seed-gen still has an mkdir/age lock" || ok "seed-gen has no mkdir or age-steal lock left"

echo "$pass passed, $fail failed"; [ $fail -eq 0 ]
