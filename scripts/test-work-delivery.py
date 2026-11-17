#!/usr/bin/env python3
"""srv/workdelivery.py and canopy-work: captured direction reaches its worker as the full
accumulated packet, receipts say only what the transport proved, and no crash point causes a
second turn. Fake transports and stub `claude`/`claude-say` executables in a temp directory; no
real session is ever addressed and no pane is read."""
import json
import os
import stat
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from srv import workdelivery as wd, workjournal as wj  # noqa: E402

failures = 0
TMP = tempfile.mkdtemp(prefix="work-delivery-test-")
n = 0
SID = "0f0e0d0c-1111-2222-3333-444455556666"


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


def raises(exc, fn):
    try:
        fn()
    except exc as e:
        return e
    return None


class Clock:
    def __init__(self):
        self.t = 1_800_000_000.0

    def __call__(self):
        return self.t


class Fake:
    """A transport whose outcome a test chooses; it records every payload it was handed."""
    host = "fake"

    def __init__(self, outcome="acknowledged"):
        self.outcome = outcome
        self.sent = []

    def handles(self, target):
        return target.startswith("fake:")

    def payload(self, packet, note):
        return wd.envelope(packet, note)

    def submit(self, target, payload, journal, receipt_id):
        self.sent.append((target, payload))
        o = self.outcome
        if o == "failed":
            raise wd.Failed("no such session")
        if o == "crash":
            raise KeyboardInterrupt("dispatcher killed mid-hand-off")
        if o == "raise":
            raise RuntimeError("pane vanished after typing")
        return (o, None if o == "acknowledged" else "left as a draft")


class Crash(BaseException):
    pass


def crash_at(stage):
    def fault(s):
        if s == stage:
            raise Crash(stage)
    return fault


def fresh():
    global n
    n += 1
    clock = Clock()
    j = wj.Journal(os.path.join(TMP, f"d{n}", "journal.sqlite3"), clock=clock)
    j.register_source("show", adapter="test")
    return j, clock


def say(j, work, mid, text, seq, target="fake:s1", conv="c1", **kw):
    if j.binding("show", conv) is None:
        j.bind("show", conv, [work], by="test")
    r = j.capture(source="show", conversation=conv, source_message_id=mid, text=text, source_seq=seq, target=target, **kw)
    j.cover("show", conv, seq)
    return r


# ---- the envelope carries the direction itself ---------------------------------------------

j, clock = fresh()
w = j.create_work(title="Show freshness", todo_id="item", incarnation="i_item", repo="dotfiles", branch="feat/x")
say(j, w, "1", "keep the old route's response shape", 1)
j.close()
j = wj.Journal(j.path, clock=clock)
t = Fake()
res = wd.dispatch(j, [t])
r0 = res[0]
check("a message captured before a crash is delivered after it", [r["outcome"] for r in res] == ["delivered"] and len(t.sent) == 1)
check("the first delivery starts an attempt at the message's work", r0["boundary"] == "start" and j.attempt(r0["attempt_id"])["generations"] == {w: 1})
say(j, w, "2", "also show last touch", 2, note="Reply in the Show thread.")
dup = say(j, w, "2", "also show last touch", 2)
res = wd.dispatch(j, [t])
payload = t.sent[-1][1]
check("a duplicate capture adds no second delivery", dup["duplicate"] and len(res) == 1 and len(t.sent) == 2)
check("the worker's payload itself holds the earlier constraint and the latest message, no fetch needed",
      "keep the old route's response shape" in payload and "also show last touch" in payload and "Reply in the Show thread." in payload)
check("the payload is the stored packet's exact text plus the note", payload == j.packet(res[0]["packet_id"])["text"] + "\nReply in the Show thread.\n")
rp = j.receipt_payload(res[0]["receipt_id"])
check("the receipt records the digest of exactly those bytes", rp["digest"] == wj.digest(payload) and rp["bytes"] == len(payload.encode()))
path = os.path.join(TMP, f"d{n}", "packets", f"{res[0]['packet_id']}.md")
check("a private copy is kept as an artifact", open(path).read() == j.packet(res[0]["packet_id"])["text"]
      and stat.S_IMODE(os.stat(path).st_mode) == 0o600 and stat.S_IMODE(os.stat(j.path).st_mode) == 0o600)
check("the next turn reuses the attempt", res[0]["boundary"] == "turn" and res[0]["attempt_id"] == r0["attempt_id"])
check("a delivered turn is not a completion", j.results(w) == [] and j.status(w)["completion"] == "none")
rep = j.report(w, "completion", "done", via="t", attempt_id=res[0]["attempt_id"], packet_id=res[0]["packet_id"])
check("citing the delivered packet completes current", rep["verdict"] == "current")

line = wd.one_line(j.packet(res[0]["packet_id"]) | {"text": j.packet(res[0]["packet_id"])["text"]}, "note")
check("the one-line form carries the same direction without a newline",
      "\n" not in line and json.loads(line.split(": ", 1)[1])["context"] == j.packet(res[0]["packet_id"])["text"])

# ---- no crash point causes a second turn ---------------------------------------------------

for stage, want_state, want_outcome in (("opened", "uncertain", "uncertain"), ("submitted", "uncertain", "uncertain"),
                                        ("receipt-settled", "acknowledged", "delivered")):
    j, clock = fresh()
    w = j.create_work()
    say(j, w, "1", "x", 1)
    t = Fake()
    raises(Crash, lambda: wd.dispatch(j, [t], fault=crash_at(stage)))
    clock.t += 61
    res = wd.dispatch(j, [t])
    sent_by_crash = 0 if stage == "opened" else 1
    check(f"crash after {stage}: recovery sends nothing again",
          len(t.sent) == sent_by_crash and res[0]["outcome"] == want_outcome and j.outbox()[0]["state"] == ("delivered" if want_outcome == "delivered" else "uncertain"), (res, t.sent))
    check(f"crash after {stage}: the receipt reads {want_state}", j.receipts()[0]["state"] == want_state)

j, clock = fresh()
w = j.create_work()
say(j, w, "1", "x", 1)
t = Fake("uncertain")
raises(Crash, lambda: wd.dispatch(j, [t], fault=crash_at("receipt-settled")))
clock.t += 61
res = wd.dispatch(j, [t])
check("uncertain before the row settled stays uncertain, not resent", len(t.sent) == 1 and res[0]["outcome"] == "uncertain")
j.requeue(res[0]["outbox_id"], by="phil")
t.outcome = "acknowledged"
res = wd.dispatch(j, [t])
check("a deliberate requeue sends again under the same message id", len(t.sent) == 2 and res[0]["outcome"] == "delivered"
      and res[0]["message_id"] == j.outbox()[0]["message_id"])
check("only uncertain or abandoned rows are requeued", raises(wj.Conflict, lambda: j.requeue(res[0]["outbox_id"], by="x")) is not None)

j, clock = fresh()
w = j.create_work()
say(j, w, "1", "x", 1)
t = Fake("failed")
res = wd.dispatch(j, [t])
check("a provably failed hand-off retries later", res[0]["outcome"] == "failed" and j.outbox()[0]["state"] == "pending")
check("not before its backoff", wd.dispatch(j, [t]) == [])
clock.t += 31
t.outcome = "acknowledged"
res = wd.dispatch(j, [t])
check("after a failure, the retry sends", res[0]["outcome"] == "delivered" and len(t.sent) == 2)

j, clock = fresh()
w = j.create_work()
say(j, w, "1", "x", 1)
res = wd.dispatch(j, [Fake("raise")])
check("an error after the hand-off began is uncertain", res[0]["outcome"] == "uncertain" and j.outbox()[0]["state"] == "uncertain")

# ---- targets, bindings, multiple workers ---------------------------------------------------

j, clock = fresh()
A, B = j.create_work(), j.create_work()
say(j, A, "1", "for some other host", 1, target="other-host:abc")
t = Fake()
res = wd.dispatch(j, [t])
check("an unsupported host is abandoned, never guessed", res[0]["outcome"] == "abandoned" and t.sent == [])
j.bind("show", "c1", [], by="unbind")
say(j, A, "2", "which one?", 2)
res = wd.dispatch(j, [t])
check("an unassigned message isn't delivered as anyone's direction", res[0]["outcome"] == "abandoned" and t.sent == [])

j, clock = fresh()
A, B = j.create_work(title="A"), j.create_work(title="B")
say(j, A, "1", "do A", 1)
j.bind("show", "c1", [B], by="switch")
first = wd.dispatch(j, [Fake()])[0]
check("a delivery after a task switch still carries the message's frozen work", j.attempt(first["attempt_id"])["generations"] == {A: 1})
say(j, B, "2", "do B", 2)
j.bind("show", "c2", [A], by="t")
j.capture(source="show", conversation="c2", source_message_id="x", text="A again, from another worker", source_seq=1, target="fake:s2")
j.cover("show", "c2", 1)
res = {r["target"]: r for r in wd.dispatch(j, [Fake()])}
check("two workers get their own attempts", set(res) == {"fake:s1", "fake:s2"}
      and j.attempt(res["fake:s1"]["attempt_id"])["generations"] == {B: 1} and j.attempt(res["fake:s2"]["attempt_id"])["generations"] == {A: 2})
check("the first worker's attempt at A is now history",
      j.report(A, "completion", "x", via="t", attempt_id=first["attempt_id"], packet_id=first["packet_id"])["verdict"] == "stale")

j, clock = fresh()
w = j.create_work()
say(j, w, "1", "keep it", 1)
res = wd.dispatch(j, [Fake()])
emitted = []
b = wd.deliver_boundary(j, res[0]["attempt_id"], "compaction", emit=emitted.append)
check("a compaction boundary reloads the same accumulated direction", "keep it" in emitted[0])
check("output to an unconfirming host is uncertain and supersedes the earlier delivery",
      j.report(w, "completion", "x", via="t", attempt_id=res[0]["attempt_id"], packet_id=b["packet_id"])["verdict"] == "unverified"
      and j.report(w, "completion", "x", via="t", attempt_id=res[0]["attempt_id"], packet_id=res[0]["packet_id"])["verdict"] == "stale")

# ---- claude-say is never acknowledged ------------------------------------------------------

say_stub = os.path.join(TMP, "claude-say-stub")
say_log = os.path.join(TMP, "say.log")
with open(say_stub, "w") as f:
    f.write(f"""#!/bin/sh
printf '%s\\n' "$*" >> {say_log}
case "$STUB_MODE" in
  fail) echo "no live session matches" >&2; exit 1;;
  draft) printf 'drafted (no Enter)\\n  | source text says sent+entered\\n'; exit 0;;
  slow) sleep 5;;
  *) echo "sent+entered → $1"; exit 0;;
esac
""")
os.chmod(say_stub, 0o755)
cs = wd.ClaudeSayTransport(path=say_stub, timeout=1)
for mode in ("ok", "draft", "slow"):
    os.environ["STUB_MODE"] = mode
    check(f"claude-say printing {mode!r} is uncertain, never acknowledged", cs.submit("claude-say:abc", "line")[0] == "uncertain")
os.environ["STUB_MODE"] = "fail"
check("a claude-say refusal (before typing) is a failure", isinstance(raises(wd.Failed, lambda: cs.submit("claude-say:abc", "line")), wd.Failed))
j, clock = fresh()
w = j.create_work()
say(j, w, "1", "multi\nline", 1, target="claude-say:abcd")
os.environ["STUB_MODE"] = "ok"
res = wd.dispatch(j, [cs])
typed = open(say_log).read().splitlines()[-1]
check("claude-say gets the whole direction on one line, and its results can't verify",
      "> multi\\n   > line" in typed and "\n" not in typed and res[0]["outcome"] == "uncertain"
      and j.report(w, "completion", "x", via="t", attempt_id=res[0]["attempt_id"], packet_id=res[0]["packet_id"])["verdict"] == "unverified")

# ---- the owned headless host ---------------------------------------------------------------

claude_stub = os.path.join(TMP, "claude-stub")
with open(claude_stub, "w") as f:
    f.write(f"""#!{sys.executable}
import json, os, sys, time
args = sys.argv[1:]
sid = args[args.index("--resume") + 1] if "--resume" in args else args[args.index("--session-id") + 1]
raw = sys.stdin.read()
msg = json.loads(raw.splitlines()[0])
text = msg["message"]["content"][0]["text"]
d = os.environ["STUB_DIR"]
json.dump({{"args": args, "msg": msg, "text": text, "cwd": os.getcwd()}}, open(os.path.join(d, f"turn-{{time.time_ns():020d}}-{{msg['uuid']}}.json"), "w"))
mode = os.environ.get("STUB_MODE", "ok")
init = {{"type": "system", "subtype": "init", "session_id": sid}}
def emit(ev):
    print(json.dumps(ev), flush=True)
def replay(text=text, uuid=msg["uuid"]):
    emit({{"type": "user", "uuid": uuid, "session_id": sid, "isReplay": True, "message": {{"role": "user", "content": [{{"type": "text", "text": text}}]}}}})
if mode == "fail":
    print("error: session not found", file=sys.stderr); sys.exit(3)
if mode == "init-reject":
    emit(init); print("error: input rejected", file=sys.stderr); sys.exit(2)
if mode == "init-only":
    emit(init); emit({{"type": "result", "subtype": "success", "is_error": False}}); sys.exit(0)
if mode == "mismatch":
    emit(init); replay(text=text + " (altered)"); sys.exit(0)
if mode == "other-uuid":
    emit(init); replay(uuid="00000000-0000-0000-0000-000000000000"); sys.exit(0)
if mode == "stderr-replay":
    emit(init)
    print(json.dumps({{"type": "user", "uuid": msg["uuid"], "message": {{"content": [{{"type": "text", "text": text}}]}}}}), file=sys.stderr)
    sys.exit(0)
if mode == "silent":
    time.sleep(3); sys.exit(0)
emit(init); replay()
if mode == "compact":
    import subprocess
    settings = json.loads(args[args.index("--settings") + 1])
    for group in settings["hooks"]["SessionStart"]:
        if group["matcher"] == "compact":
            for h in group["hooks"]:
                out = subprocess.run(h["command"], shell=True, capture_output=True, text=True)
                open(os.path.join(d, "compacted.txt"), "w").write(out.stdout)
time.sleep(float(os.environ.get("STUB_HOLD", "0")))
if mode == "late-fail":
    emit({{"type": "result", "subtype": "error_during_execution", "is_error": True, "result": "permission denied"}}); sys.exit(1)
emit({{"type": "result", "subtype": "success", "is_error": False, "session_id": sid}})
""")
os.chmod(claude_stub, 0o755)
stub_dir = os.path.join(TMP, "turns")
os.makedirs(stub_dir)
os.environ["STUB_DIR"] = stub_dir
hc = wd.HeadlessClaudeTransport(path=claude_stub, timeout=2, poll=0.02)


def turns():
    return [json.load(open(os.path.join(stub_dir, f))) for f in sorted(x for x in os.listdir(stub_dir) if x.startswith("turn-"))]


def until(cond, secs=15):
    """Waits, bounded, for a condition the code under test makes durable; returns whether it held."""
    end = time.time() + secs
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.05)
    return cond()


def wait_turns_end(j, worker, secs=15):
    """Until the worker's turns have recorded their ends (an unknown identity is still waited out)."""
    until(lambda: not j.turns(worker, running=True), secs)


j, clock = fresh()
w = j.create_work(title="H")
target = wd.HeadlessClaudeTransport.register(j, SID, cwd=TMP, allowed_tools="Read,Grep", boot_prompt="You answer the deck's thread.")
check("only a session uuid names a headless worker", hc.handles(target) and not hc.handles("claude-headless:abc"))
say(j, w, "1", "keep the old API", 1, target=target)
os.environ["STUB_MODE"] = "ok"
res = wd.dispatch(j, [hc, cs])
first_turn = turns()[0]
a = first_turn["args"]
check("the host replaying this exact input is the acknowledgement", res[0]["outcome"] == "delivered" and j.receipts()[0]["state"] == "acknowledged", res)
check("the turn runs with stream-json replay and no permission prompts, inside its allowlist",
      all(x in a for x in ("--replay-user-messages", "--input-format", "--output-format")) and a[a.index("--permission-prompts") + 1] == "none"
      and a[a.index("--allowedTools") + 1] == "Read,Grep" and "--dangerously-skip-permissions" not in a)
check("the first turn boots the session with the boot prompt and the full packet as one user message",
      "--session-id" in a and first_turn["text"].startswith("You answer the deck's thread.") and "keep the old API" in first_turn["text"]
      and first_turn["cwd"] == os.path.realpath(TMP))
wait_turns_end(j, target)
check("the owned wrapper records how the turn ended", j.turns(target)[0]["outcome"] == "succeeded")
check("a successful turn is not a completion", j.results(w) == [])
say(j, w, "2", "also show last touch", 2, target=target)
res = wd.dispatch(j, [hc, cs])
second = turns()[1]
check("later turns resume the session and carry all direction so far",
      "--resume" in second["args"] and "keep the old API" in second["text"] and "also show last touch" in second["text"]
      and not second["text"].startswith("You answer"))
check("a qualified completion needs no worker filesystem fetch",
      j.report(w, "completion", "x", via="t", attempt_id=res[0]["attempt_id"], packet_id=res[0]["packet_id"])["verdict"] == "current")
wait_turns_end(j, target)

os.environ["STUB_HOLD"] = "1.5"
say(j, w, "3", "third", 3, target=target)
wd.dispatch(j, [hc, cs])
check("the worker's turn process is observed running", wd.HeadlessClaudeTransport.observe(j, target)[0]["observed"] == "running")
say(j, w, "4", "fourth while busy", 4, target=target)
os.environ["STUB_HOLD"] = "0"
res = wd.dispatch(j, [hc, cs])
row = next(o for o in j.outbox() if o["outbox_id"] == res[0]["outbox_id"])
check("one turn at a time: a busy worker's message is queued, unsent, spending no attempt",
      res[0]["outcome"] == "deferred" and len(turns()) == 3 and row["state"] == "pending" and row["attempts"] == 0 and j.receipts(outbox_id=row["outbox_id"]) == [])
delivered = until(lambda: next(o for o in j.outbox() if o["outbox_id"] == row["outbox_id"])["state"] == "delivered")
check("when the running turn ends, the owned host delivers the queued direction itself, with everything",
      delivered and len(turns()) == 4 and "third" in turns()[3]["text"] and "fourth while busy" in turns()[3]["text"])
wait_turns_end(j, target)
check("a finished turn is observed finished", wd.HeadlessClaudeTransport.observe(j, target) == [] and j.turns(target)[0]["outcome"] == "succeeded")

for mode, want in (("fail", "failed"), ("init-reject", "failed"), ("init-only", "uncertain"), ("mismatch", "uncertain"),
                   ("other-uuid", "uncertain"), ("stderr-replay", "uncertain"), ("silent", "uncertain")):
    j, clock = fresh()
    w = j.create_work()
    sid = f"0f0e0d0c-1111-2222-3333-{len(mode) * 7:012d}"
    tg = wd.HeadlessClaudeTransport.register(j, sid, cwd=TMP, allowed_tools="Read")
    say(j, w, "1", "x", 1, target=tg)
    os.environ["STUB_MODE"] = mode
    res = wd.dispatch(j, [hc])
    r = j.report(w, "completion", "x", via="t", attempt_id=res[0]["attempt_id"], packet_id=res[0]["packet_id"])
    check(f"a turn that is {mode!r} is {want} and its completion unverified", res[0]["outcome"] == want and j.receipts()[0]["state"] == want
          and r["verdict"] == "unverified", (res, r["reason"]))
os.environ["STUB_MODE"] = "late-fail"
j, clock = fresh()
w = j.create_work()
tg = wd.HeadlessClaudeTransport.register(j, SID, cwd=TMP, allowed_tools="Read")
say(j, w, "1", "x", 1, target=tg)
res = wd.dispatch(j, [hc])
wait_turns_end(j, tg)
check("a turn that fails after accepting its input: delivery acknowledged, turn failure observable",
      res[0]["outcome"] == "delivered" and j.turns(tg)[0]["outcome"] == "failed" and "permission denied" in j.turns(tg)[0]["detail"])
os.environ["STUB_MODE"] = "ok"
j, clock = fresh()
w = j.create_work()
say(j, w, "1", "x", 1, target="claude-headless:" + SID)
res = wd.dispatch(j, [hc])
check("an unregistered headless worker is never started", res[0]["outcome"] == "failed" and "not registered" in res[0]["detail"])

# Compaction inside a managed turn reloads the canonical packet through the host's own hook.
j, clock = fresh()
w = j.create_work()
tg = wd.HeadlessClaudeTransport.register(j, SID, cwd=TMP, allowed_tools="Read")
say(j, w, "1", "keep the old route", 1, target=tg)
say(j, w, "2", "and show last touch", 2, target=None)
os.environ["STUB_MODE"] = "compact"
res = wd.dispatch(j, [hc])
wait_turns_end(j, tg)
a = turns()[-1]["args"]
settings = json.loads(a[a.index("--settings") + 1])
check("each turn carries a compaction hook for its own attempt, and no resume hook",
      [g["matcher"] for g in settings["hooks"]["SessionStart"]] == ["compact"] and res[0]["attempt_id"] in json.dumps(settings))
until(lambda: os.path.exists(os.path.join(stub_dir, "compacted.txt")))
reloaded = open(os.path.join(stub_dir, "compacted.txt")).read()
check("after compaction the session gets the whole accumulated direction back",
      "keep the old route" in reloaded and "and show last touch" in reloaded and "revision 2" in reloaded)
last = j.receipts(attempt_id=res[0]["attempt_id"])[-1]
check("the compaction reload is recorded as an uncertain receipt", last["boundary"] == "compaction" and last["state"] == "uncertain")
check("results after compaction stay unverified; the pre-compaction delivery is superseded",
      j.report(w, "completion", "x", via="t", attempt_id=res[0]["attempt_id"], packet_id=last["packet_id"])["verdict"] == "unverified"
      and j.report(w, "completion", "x", via="t", attempt_id=res[0]["attempt_id"], packet_id=res[0]["packet_id"])["verdict"] == "stale")
say(j, w, "3", "third", 3, target=tg)
os.environ["STUB_MODE"] = "ok"
res = wd.dispatch(j, [hc])
check("the next confirmed turn qualifies again",
      j.report(w, "completion", "x", via="t", attempt_id=res[0]["attempt_id"], packet_id=res[0]["packet_id"])["verdict"] == "current")
wait_turns_end(j, tg)

# A crashed wrapper (host crash) leaves no end record: observation says lost, not working.
j, clock = fresh()
w = j.create_work()
tg = wd.HeadlessClaudeTransport.register(j, SID, cwd=TMP, allowed_tools="Read")
os.environ["STUB_HOLD"] = "5"
say(j, w, "1", "x", 1, target=tg)
wd.dispatch(j, [hc])
pid = j.turns(tg)[0]["pid"]
os.killpg(pid, 9)
time.sleep(0.2)
obs = wd.HeadlessClaudeTransport.observe(j, tg)
check("a turn whose process died without its record is observed lost", obs[0]["observed"] == "lost" and j.turns(tg)[0]["outcome"] == "lost")
j.db.execute("UPDATE turn SET outcome = 'running', ended_at = NULL, start_token = NULL, pid = ? WHERE receipt_id = ?", (os.getpid(), j.turns(tg)[0]["receipt_id"]))
check("a live pid without a start token is unknown, never this worker", wd.HeadlessClaudeTransport.observe(j, tg)[0]["observed"] == "unknown")
j.db.execute("UPDATE turn SET start_token = 'Mon Jan  1 00:00:00 2001' WHERE outcome = 'running'")
check("a reused pid with another start time is not this worker", wd.HeadlessClaudeTransport.observe(j, tg)[0]["observed"] == "lost")
real_start = wd._start_time
wd._start_time = lambda pid: None
j.db.execute("UPDATE turn SET outcome = 'running', ended_at = NULL, start_token = 'Mon Jan  1 00:00:00 2001', pid = ? WHERE receipt_id = ?",
             (os.getpid(), j.turns(tg)[0]["receipt_id"]))
check("a live process that can't be inspected is unknown, not lost", wd.HeadlessClaudeTransport.observe(j, tg)[0]["observed"] == "unknown"
      and j.turns(tg)[0]["outcome"] == "running")
say(j, w, "2", "while unknown", 2, target=tg)
clock.t += 61
res = wd.dispatch(j, [hc])
check("and no second turn launches beside it; the message stays queued", res[0]["outcome"] == "deferred" and len(j.turns(tg)) == 1)
wd._start_time = real_start
j.db.execute("UPDATE turn SET pid = 999999 WHERE outcome = 'running'")
check("a pid that no longer exists is lost", wd.HeadlessClaudeTransport.observe(j, tg)[0]["observed"] == "lost")
os.environ["STUB_HOLD"] = "0"

# Two dispatchers racing for one worker: only one turn launches.
cpath = os.path.join(TMP, "race", "journal.sqlite3")
j = wj.Journal(cpath)
j.register_source("show", adapter="test")
w = j.create_work()
tg = wd.HeadlessClaudeTransport.register(j, SID, cwd=TMP, allowed_tools="Read")
j.bind("show", "c1", [w], by="t")
for k in (1, 2):
    j.capture(source="show", conversation="c1", source_message_id=str(k), text=f"m{k}", source_seq=k, target=tg)
j.cover("show", "c1", 2)
j.close()
before = len(turns())
racer = f"""
import json, sys
sys.path.insert(0, {HERE!r})
from srv import workdelivery as wd, workjournal as wj
j = wj.Journal({cpath!r})
print(json.dumps(wd.dispatch(j, [wd.HeadlessClaudeTransport(path={claude_stub!r}, timeout=3, poll=0.02)], limit=1)))
"""
env_race = {**os.environ, "STUB_HOLD": "1.5", "STUB_MODE": "ok"}
ps = [subprocess.Popen([sys.executable, "-c", racer], stdout=subprocess.PIPE, text=True, env=env_race) for _ in range(2)]
outs = [json.loads(p.communicate()[0])[0]["outcome"] for p in ps]
check("two dispatchers racing for one worker launch exactly one turn; the other queues", sorted(outs) == ["deferred", "delivered"]
      and len(turns()) == before + 1, outs)
j = wj.Journal(cpath)
wait_turns_end(j, tg)

# Registration racing a boot acknowledgement: neither overwrites the other.
j, clock = fresh()
reg_sid = "0f0e0d0c-9999-2222-3333-444455556666"
wd.HeadlessClaudeTransport.register(j, reg_sid, cwd=TMP, allowed_tools="Read", boot_prompt="boot")
real_write = wd._private_write
acked = []


def write_after_ack(path, text):
    if path.endswith(f"{reg_sid}.json") and not acked:
        acked.append(1)
        t = __import__("threading").Thread(target=lambda: wd.HeadlessClaudeTransport._update(j, reg_sid, {"booted": True}))
        t.start()
        t.join(0.3)
        acked.append(t)
    real_write(path, text)


wd._private_write = write_after_ack
wd.HeadlessClaudeTransport.register(j, reg_sid, cwd=TMP, allowed_tools="Read,Grep", boot_prompt="boot")
wd._private_write = real_write
acked[1].join()
conf = wd.HeadlessClaudeTransport.config(j, reg_sid)
check("a boot acknowledgement racing a registration survives it, and the registration lands",
      conf["booted"] is True and conf["allowed_tools"] == "Read,Grep", conf)
j2, _ = fresh()
tg2 = wd.HeadlessClaudeTransport.register(j2, SID, cwd=TMP, allowed_tools="Read")
w2 = j2.create_work()
say(j2, w2, "1", "x", 1, target=tg2)
wd.dispatch(j2, [hc])
wait_turns_end(j2, tg2)
wd._private_write(wd.HeadlessClaudeTransport._conf_path(j2, SID), json.dumps({**wd.HeadlessClaudeTransport.config(j2, SID), "booted": False}))
say(j2, w2, "2", "y", 2, target=tg2)
wd.dispatch(j2, [hc])
check("a lost boot flag can't restart an acknowledged session: the next turn resumes", "--resume" in turns()[-1]["args"])
wait_turns_end(j2, tg2)

# ---- reading worker state without writing ---------------------------------------------------

rpath = os.path.join(TMP, "ro", "journal.sqlite3")
renv = {**os.environ, "CANOPY_WORK_JOURNAL": rpath}


def ro(*a):
    p = subprocess.run([sys.executable, os.path.join(HERE, "canopy-work"), *a], capture_output=True, text=True, env=renv)
    return p.returncode, json.loads(p.stdout) if p.stdout.strip().startswith("{") else p.stdout, p.stderr


rc, out, err = ro("worker", "--session", SID)
check("reading a worker with no journal says none and creates nothing", rc == 0 and out == {"journal": "absent", "state": "none"}
      and not os.path.exists(rpath) and not os.path.exists(os.path.dirname(rpath)), (out, err))
j = wj.Journal(rpath)
j.register_source("show", adapter="test")
w = j.create_work()
tg = wd.HeadlessClaudeTransport.register(j, SID, cwd=TMP, allowed_tools="Read")
check("a worker that never ran a turn reads none", ro("worker", "--session", SID)[1] == {"state": "none"})
os.environ["STUB_HOLD"] = "1"
say(j, w, "1", "x", 1, target=tg)
wd.dispatch(j, [hc])
os.environ["STUB_HOLD"] = "0"
check("a worker in a turn reads running", ro("worker", "--session", SID)[1]["state"] == "running")
wait_turns_end(j, tg)
st = ro("worker", "--session", SID)[1]
check("a finished turn reads ended, with its outcome", st["state"] == "ended" and st["outcome"] == "succeeded", st)
j.db.execute("UPDATE turn SET outcome = 'running', ended_at = NULL, pid = 999999")
mtime = os.stat(rpath).st_mtime_ns
st = ro("worker", "--session", SID)[1]
check("a vanished turn reads lost, and the read records nothing", st["state"] == "ended" and st["outcome"] == "lost"
      and j.turns(tg)[0]["outcome"] == "running" and os.stat(rpath).st_mtime_ns == mtime, st)
_, ctx, _ = ro("context", "--work", w)
check("context reads read-only", ctx["work"]["work_id"] == w and j.turns(tg)[0]["outcome"] == "running")

# ---- the command line, end to end ----------------------------------------------------------

env = {**os.environ, "CANOPY_WORK_JOURNAL": os.path.join(TMP, "cli", "journal.sqlite3"), "CANOPY_WORK_CLAUDE": claude_stub,
       "CANOPY_TODO_DIR": os.path.join(TMP, "cli", "todo"),
       "CANOPY_WORK_CLAUDE_SAY": say_stub, "STUB_MODE": "ok"}


def cli(*a, stdin=None):
    p = subprocess.run([sys.executable, os.path.join(HERE, "canopy-work"), *a], input=stdin, capture_output=True, text=True, env=env)
    return p.returncode, (json.loads(p.stdout) if p.stdout.strip().startswith(("{", "[")) else p.stdout), p.stderr


SID2 = "0f0e0d0c-aaaa-bbbb-cccc-444455556666"
subprocess.run([sys.executable, os.path.join(HERE, "canopy-todo"), "add", "Item one", "--kind", "build", "--area", "test",
                "--why", "fixture", "--id", "item-1"], env=env, capture_output=True, check=True)
_, wout, _ = cli("work", "--todo", "item-1", "--repo", "dotfiles", "--branch", "feat/y")
W = wout["work_id"]
cli("source", "--source", "show", "--adapter", "show-thread")
cli("bind", "--source", "show", "--conversation", "deck#s1", "--work", W, "--by", "test")
_, host, _ = cli("host", "--session", SID2, "--cwd", TMP, "--allowed-tools", "Read")
rc, cap, _ = cli("capture", "--source", "show", "--conversation", "deck#s1", "--message-id", "u-1", "--seq", "1",
                 "--target", host["target"], stdin="line one\nline two\n")
cli("cover", "--source", "show", "--conversation", "deck#s1", "--through", "1")
rc, res, err = cli("dispatch")
check("the CLI captures from stdin and delivers to the owned host", rc == 0 and cap["works"] == {W: 1} and res[0]["outcome"] == "delivered", err)
_, done, _ = cli("report", "--work", W, "completion", "done", "--attempt", res[0]["attempt_id"], "--packet", res[0]["packet_id"])
_, st, _ = cli("status", "--todo", "item-1")
check("a report citing the delivered packet is current", done["verdict"] == "current" and st["completion"] == "current")
cli("exclude", "--source", "show", "--conversation", "private")
rc, _, err = cli("capture", "--source", "show", "--conversation", "private", "--message-id", "p", "--work", W, stdin="secret")
check("an excluded conversation is refused with its own exit code, keeping nothing",
      rc == 2 and "NotCollected" in err and "secret" not in json.dumps(cli("context", "--work", W)[1]))

print(f"\n{failures} failure(s)" if failures else "\nall passed")
sys.exit(1 if failures else 0)
