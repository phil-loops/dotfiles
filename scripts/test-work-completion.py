#!/usr/bin/env python3
"""srv/workjournal.py's qualified results: a completion is current only when a managed attempt's
latest generation cites its latest acknowledged delivery of the work's current revision, decided
atomically with the write. Isolated temp journals; no delivery happens here."""
import os
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from srv import workjournal as wj  # noqa: E402

failures = 0
TMP = tempfile.mkdtemp(prefix="work-completion-test-")
n = 0


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


def fresh(**kw):
    global n
    n += 1
    j = wj.Journal(os.path.join(TMP, f"j{n}.sqlite3"), **kw)
    j.register_source("show", adapter="test")
    return j


def say(j, work, mid, text, seq, cover=True, **kw):
    if not j.binding("show", f"c-{work}"):
        j.bind("show", f"c-{work}", [work], by="test")
    out = j.capture(source="show", conversation=f"c-{work}", source_message_id=mid, text=text, source_seq=seq, **kw)
    if cover:
        j.cover("show", f"c-{work}", seq)
    return out


def deliver(j, attempt_id, boundary="turn", state="acknowledged"):
    packet = j.prepare(attempt_id)
    rid = j.open_receipt(packet["packet_id"], boundary=boundary)
    if state:
        j.settle_receipt(rid, state)
    return rid, packet


# ---- the happy path, then new direction ----------------------------------------------------

j = fresh()
w = j.create_work(todo_id="item", incarnation="i_1")
say(j, w, "1", "build the journal", 1)
a = j.begin_attempt([w], worker="session:1", host="claude-say", managed=True)
rid, packet = deliver(j, a["attempt_id"], boundary="start")
check("a packet carries the revision and accumulated direction", packet["items"][0]["revision"] == 1
      and [m["text"] for m in packet["items"][0]["direction"]] == ["build the journal"])
r = j.report(w, "completion", "done", via="test", attempt_id=a["attempt_id"], receipt_id=rid)
check("a managed attempt citing its acknowledged delivery of the current revision completes current", r["verdict"] == "current", r)
check("status says the completion answers current direction", j.status(w)["completion"] == "current")
say(j, w, "2", "also show last touch", 2)
st = j.status(w)
check("direction after a valid completion makes it historical, not erased",
      st["completion"] == "historical" and st["qualified_completion"]["result_id"] == r["result_id"] and st["revision"] == 2)
again = j.report(w, "completion", "done again", via="test", attempt_id=a["attempt_id"], receipt_id=rid)
check("completing again on the old delivery is stale", again["verdict"] == "stale" and "revision 1" in again["reason"], again)
check("the stale completion is history, and current work is pending", j.status(w)["completion"] == "stale" and len(j.results(w, kind="completion")) == 2)
rid2, _ = deliver(j, a["attempt_id"])
r2 = j.report(w, "completion", "with last touch", via="test", attempt_id=a["attempt_id"], receipt_id=rid2)
check("after the new direction is delivered, completion is current again", r2["verdict"] == "current" and j.status(w)["completion"] == "current")

# ---- revision 2 arrives while revision 1 runs -----------------------------------------------

j = fresh()
w = j.create_work()
say(j, w, "1", "first", 1)
a = j.begin_attempt([w], worker="s", host="claude-say", managed=True)
rid, _ = deliver(j, a["attempt_id"])
j.report(w, "progress", "halfway", via="test", attempt_id=a["attempt_id"], receipt_id=rid)
say(j, w, "2", "change of plan", 2)
r = j.report(w, "completion", "finished the first plan", via="test", attempt_id=a["attempt_id"], receipt_id=rid)
check("revision 1's output can't complete revision 2", r["verdict"] == "stale" and r["delivered_revision"] == 1 and r["revision_at_report"] == 2)
check("revision 1's progress stays readable", j.status(w)["last_progress"]["text"] == "halfway")

# ---- legacy callers and unmanaged hosts ----------------------------------------------------

j = fresh()
w = j.create_work()
say(j, w, "1", "x", 1)
legacy = j.report(w, "completion", "state=done", via="canopy-todo")
check("a legacy completion is recorded but unverified", legacy["verdict"] == "unverified" and j.status(w)["completion"] == "unverified")
u = j.begin_attempt([w], worker="headless", host="deck-agent", managed=False)
check("an unmanaged host gets no receipts", raises(wj.JournalError, lambda: j.open_receipt(j.prepare(u["attempt_id"])["packet_id"], boundary="start")) is not None)
ur = j.report(w, "completion", "done", via="test", attempt_id=u["attempt_id"])
check("an unmanaged host's completion is unverified", ur["verdict"] == "unverified" and "deck-agent" in ur["reason"])
check("an unmanaged completion never reads as current", j.status(w)["completion"] == "unverified")
m = j.begin_attempt([w], worker="s", host="claude-say", managed=True)
check("a managed attempt without a cited receipt is unverified",
      j.report(w, "completion", "trust me, revision 1", via="test", attempt_id=m["attempt_id"])["verdict"] == "unverified")

# ---- attempts, generations, receipts -------------------------------------------------------

j = fresh()
w = j.create_work()
say(j, w, "1", "x", 1)
a1 = j.begin_attempt([w], worker="s1", host="claude-say", managed=True)
r1, _ = deliver(j, a1["attempt_id"])
a2 = j.begin_attempt([w], worker="s2", host="claude-say", managed=True)
check("generations advance per work", a1["generations"][w] == 1 and a2["generations"][w] == 2)
old = j.report(w, "completion", "late", via="test", attempt_id=a1["attempt_id"], receipt_id=r1)
check("a superseded attempt's completion is stale even at the current revision", old["verdict"] == "stale" and "newer attempt" in old["reason"])
check("a superseded attempt can't receive context", raises(wj.Conflict, lambda: deliver(j, a1["attempt_id"])) is not None)
check("citing another attempt's receipt is refused", raises(wj.Conflict, lambda: j.report(w, "completion", "x", via="t", attempt_id=a2["attempt_id"], receipt_id=r1)) is not None)
r2, _ = deliver(j, a2["attempt_id"], state=None)
check("a delivery still sending doesn't qualify", j.report(w, "completion", "x", via="t", attempt_id=a2["attempt_id"], receipt_id=r2)["verdict"] == "unverified")
j.settle_receipt(r2, "uncertain", "no echo")
check("an uncertain delivery doesn't qualify", j.report(w, "completion", "x", via="t", attempt_id=a2["attempt_id"], receipt_id=r2)["verdict"] == "unverified")
j.settle_receipt(r2, "acknowledged")
j.settle_receipt(r2, "acknowledged")
check("a later acknowledgement qualifies it; replaying the acknowledgement is harmless",
      j.report(w, "completion", "x", via="t", attempt_id=a2["attempt_id"], receipt_id=r2)["verdict"] == "current")
check("an acknowledged receipt can't be rewritten as failed", raises(wj.Conflict, lambda: j.settle_receipt(r2, "failed")) is not None)
j.end_attempt(a2["attempt_id"], "worker exited")
check("an ended attempt's report is stale", j.report(w, "progress", "x", via="t", attempt_id=a2["attempt_id"], receipt_id=r2)["verdict"] == "stale")
check("an ended attempt gets no context", raises(wj.JournalError, lambda: j.prepare(a2["attempt_id"])) is not None)
check("results are immutable history", raises(Exception, lambda: j.db.execute("UPDATE result SET verdict = 'current'")) is not None)

# ---- compaction and resume -----------------------------------------------------------------

j = fresh()
w = j.create_work()
say(j, w, "1", "keep the old route", 1)
a = j.begin_attempt([w], worker="s", host="claude-say", managed=True)
before, _ = deliver(j, a["attempt_id"], boundary="start")
after, packet = deliver(j, a["attempt_id"], boundary="compaction", state=None)
check("compaction re-delivers the same accumulated direction", [m["text"] for m in packet["items"][0]["direction"]] == ["keep the old route"])
check("after compaction, the pre-compaction delivery no longer qualifies",
      j.report(w, "completion", "x", via="t", attempt_id=a["attempt_id"], receipt_id=before)["verdict"] == "stale")
check("until the compaction delivery is acknowledged, nothing qualifies",
      j.report(w, "completion", "x", via="t", attempt_id=a["attempt_id"], receipt_id=after)["verdict"] == "unverified")
j.settle_receipt(after, "acknowledged")
check("the acknowledged compaction delivery qualifies",
      j.report(w, "completion", "x", via="t", attempt_id=a["attempt_id"], receipt_id=after)["verdict"] == "current")
failed, _ = deliver(j, a["attempt_id"], boundary="resume", state="failed")
check("a failed re-delivery doesn't displace the last good one",
      j.report(w, "completion", "x", via="t", attempt_id=a["attempt_id"], receipt_id=after)["verdict"] == "current")

# ---- multiple items in one turn ------------------------------------------------------------

j = fresh()
A, B = j.create_work(), j.create_work()
say(j, A, "a1", "A first", 1)
say(j, B, "b1", "B first", 1)
a = j.begin_attempt([A, B], worker="s", host="claude-say", managed=True)
rid, packet = deliver(j, a["attempt_id"])
check("one receipt records each item's revision", j.receipts(attempt_id=a["attempt_id"])[0]["revisions"] == {A: 1, B: 1})
say(j, B, "b2", "B changed", 2)
check("new direction for B leaves A's completion current", j.report(A, "completion", "x", via="t", attempt_id=a["attempt_id"], receipt_id=rid)["verdict"] == "current")
check("and makes B's stale", j.report(B, "completion", "x", via="t", attempt_id=a["attempt_id"], receipt_id=rid)["verdict"] == "stale")
check("reporting for an item outside the attempt is refused",
      raises(wj.Conflict, lambda: j.report(j.create_work(), "completion", "x", via="t", attempt_id=a["attempt_id"])) is not None)

# ---- crash mid-hand-off --------------------------------------------------------------------

j = fresh()
w = j.create_work()
say(j, w, "1", "x", 1, target="session:s")
a = j.begin_attempt([w], worker="session:s", host="claude-say", managed=True)
ob = j.outbox()[0]["outbox_id"]
rid = j.open_receipt(j.prepare(a["attempt_id"])["packet_id"], boundary="turn", outbox_id=ob)
check("a dispatcher dying mid-hand-off leaves an uncertain receipt, found by its outbox row",
      j.abandon_open_receipts(ob, "dispatcher died") == 1 and j.receipts(outbox_id=ob)[0]["state"] == "uncertain")
check("its delivery can't qualify a completion", j.report(w, "completion", "x", via="t", attempt_id=a["attempt_id"], receipt_id=rid)["verdict"] == "unverified")

# ---- the receipt is the coordinator's packet, not the caller's claim -----------------------

j = fresh()
w = j.create_work()
say(j, w, "1", "Keep old API", 1)
a = j.begin_attempt([w], worker="s", host="claude-say", managed=True)
packet = j.prepare(a["attempt_id"])
check("the packet's text is the exact stored hand-off, pinned by digest",
      j.packet(packet["packet_id"])["text"] == packet["text"] and wj.digest(packet["text"]) == packet["digest"] and "Keep old API" in packet["text"])
say(j, w, "2", "Also keep the new constraint", 2)
packet["items"][0]["revision"] = 2
check("a packet outdated by new direction can't be handed off, whatever the caller edits",
      raises(wj.Conflict, lambda: j.open_receipt(packet["packet_id"], boundary="turn")) is not None)
check("stored packets are immutable", raises(Exception, lambda: j.db.execute("UPDATE packet_work SET revision = 2")) is not None
      and raises(Exception, lambda: j.db.execute("UPDATE packet SET text = 'x'")) is not None)
fresh_packet = j.prepare(a["attempt_id"])
rid = j.open_receipt(fresh_packet["packet_id"], boundary="turn")
check("a receipt's revisions come from its stored packet", j.receipts(attempt_id=a["attempt_id"])[-1]["revisions"] == {w: 2}
      and "Also keep the new constraint" in fresh_packet["text"] and "Keep old API" in fresh_packet["text"])
j.settle_receipt(rid, "acknowledged")
check("a worker may cite the packet; its newest delivery stands for it",
      j.report(w, "completion", "x", via="t", attempt_id=a["attempt_id"], packet_id=fresh_packet["packet_id"])["verdict"] == "current")
undelivered = j.prepare(a["attempt_id"])
check("citing a packet that was never handed off is unverified",
      j.report(w, "completion", "x", via="t", attempt_id=a["attempt_id"], packet_id=undelivered["packet_id"])["verdict"] == "unverified")

# ---- a failed delivery, and capture coverage -----------------------------------------------

j = fresh()
w = j.create_work()
say(j, w, "1", "x", 1)
a = j.begin_attempt([w], worker="s", host="claude-say", managed=True)
failed, _ = deliver(j, a["attempt_id"], state="failed")
r = j.report(w, "completion", "x", via="t", attempt_id=a["attempt_id"], receipt_id=failed)
check("citing a failed delivery is recorded as unverified, not a crash", r["verdict"] == "unverified" and "failed" in r["reason"], r)

j = fresh()
w = j.create_work()
say(j, w, "1", "x", 1, cover=False)
a = j.begin_attempt([w], worker="s", host="claude-say", managed=True)
rid, _ = deliver(j, a["attempt_id"])
r = j.report(w, "completion", "x", via="t", attempt_id=a["attempt_id"], receipt_id=rid)
check("unknown capture coverage can't earn a current completion", r["verdict"] == "unverified" and "unknown" in r["reason"], r)
j.cover("show", f"c-{w}", 2)
r = j.report(w, "completion", "x", via="t", attempt_id=a["attempt_id"], receipt_id=rid)
check("a gap in capture can't either", r["verdict"] == "unverified" and "gaps" in r["reason"], r)
j.set_connected("show", False)
check("nor a disconnected source", "unknown" in j.report(w, "completion", "x", via="t", attempt_id=a["attempt_id"], receipt_id=rid)["reason"])

j = fresh()
w = j.create_work()
j.bind("show", "owned", [w], by="t")
j.cover("show", "owned", 0)
a = j.begin_attempt([w], worker="s", host="claude-say", managed=True)
rid, _ = deliver(j, a["attempt_id"])
check("a known-empty owned conversation is complete coverage", j.coverage(w)["state"] == "complete"
      and j.report(w, "completion", "x", via="t", attempt_id=a["attempt_id"], receipt_id=rid)["verdict"] == "current")

# ---- the verdict and new direction serialize -----------------------------------------------

path = os.path.join(TMP, "race.sqlite3")
j = wj.Journal(path)
j.register_source("show", adapter="test")
w = j.create_work()
say(j, w, "1", "x", 1)
a = j.begin_attempt([w], worker="s", host="claude-say", managed=True)
rid, _ = deliver(j, a["attempt_id"])
landed = {}


def capture_now():
    other = wj.Journal(path)
    landed["rev"] = say(other, w, "2", "new direction mid-verdict", 2)["works"][w]
    landed["at"] = time.time()


def hold(stage):
    if stage == "verdict":
        t = threading.Thread(target=capture_now)
        t.start()
        time.sleep(0.4)
        landed["blocked"] = "rev" not in landed
        landed["thread"] = t


racer = wj.Journal(path, fault=hold)
r = racer.report(w, "completion", "x", via="t", attempt_id=a["attempt_id"], receipt_id=rid)
landed["thread"].join()
check("new direction can't land between the verdict and its write", landed["blocked"] and r["verdict"] == "current" and landed["rev"] == 2)
check("it lands after, making that completion historical", j.status(w)["completion"] == "historical")

# ---- concurrent input and completion across processes --------------------------------------

import subprocess  # noqa: E402

path = os.path.join(TMP, "procs.sqlite3")
j = wj.Journal(path)
j.register_source("show", adapter="test")
w = j.create_work()
j.bind("show", "c", [w], by="t")
j.capture(source="show", conversation="c", source_message_id="0", text="start", source_seq=1)
j.cover("show", "c", 1)
a = j.begin_attempt([w], worker="s", host="claude-say", managed=True)
rid, _ = deliver(j, a["attempt_id"])
j.close()
capturer = f"""
import sys; sys.path.insert(0, {HERE!r})
from srv import workjournal as wj
j = wj.Journal({path!r})
for i in range(2, 60):
    j.capture(source="show", conversation="c", source_message_id=str(i), text=f"m{{i}}", source_seq=i)
"""
completer = f"""
import sys; sys.path.insert(0, {HERE!r})
from srv import workjournal as wj
j = wj.Journal({path!r})
for i in range(60):
    j.report({w!r}, "completion", "x", via="t", attempt_id={a['attempt_id']!r}, receipt_id={rid!r})
"""
ps = [subprocess.Popen([sys.executable, "-c", c]) for c in (capturer, completer)]
codes = [p.wait() for p in ps]
j = wj.Journal(path)
rows = j.results(w, kind="completion", limit=100)
bad = [r for r in rows if r["verdict"] == "current" and r["revision_at_report"] != r["delivered_revision"]]
check("every concurrent completion was judged against the revision at its own write",
      codes == [0, 0] and len(rows) == 60 and not bad and all(r["verdict"] in ("current", "stale") for r in rows))
check("once direction moved, no later completion was current",
      all(r["verdict"] == "stale" for r in rows if r["revision_at_report"] > 1) and j.status(w)["completion"] in ("historical", "stale"))

print(f"\n{failures} failure(s)" if failures else "\nall passed")
sys.exit(1 if failures else 0)
