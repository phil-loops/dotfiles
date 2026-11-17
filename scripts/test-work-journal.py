#!/usr/bin/env python3
"""srv/workjournal.py: the input-capture contract of DESIGN.md round 25, against isolated temp
journals. Real processes for the concurrency and crash cases; nothing touches the real journal."""
import os
import sqlite3
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from srv import workjournal as wj  # noqa: E402

failures = 0
TMP = tempfile.mkdtemp(prefix="work-journal-test-")


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
    def __init__(self, t=1_800_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


n = 0


def fresh(**kw):
    global n
    n += 1
    return wj.Journal(os.path.join(TMP, f"j{n}.sqlite3"), **kw)


def enrolled(j, works, conv="c1", source="show"):
    j.register_source(source, adapter="test")
    j.bind(source, conv, works, by="test")


def cap(j, mid, text, seq=None, conv="c1", source="show", **kw):
    return j.capture(source=source, conversation=conv, source_message_id=mid, text=text, source_seq=seq, **kw)


# ---- identities, bindings, exclusion --------------------------------------------------------

j = fresh()
a1 = j.create_work(repo="loops", branch="feat/x", todo_id="item-a", incarnation="i_a1")
b1 = j.create_work(repo="dotfiles", branch="feat/x")
check("same branch name in two repositories is two subjects",
      j.works_for_branch("loops", "feat/x") == [a1] and j.works_for_branch("dotfiles", "feat/x") == [b1])
check("a branch without its repository is refused", raises(wj.JournalError, lambda: j.works_for_branch(None, "feat/x")) is not None)
check("one live work per tracker item", raises(wj.Conflict, lambda: j.create_work(todo_id="item-a", incarnation="i_a1")) is not None)
check("a tracker link needs its incarnation", raises(wj.JournalError, lambda: j.create_work(todo_id="item-b")) is not None)

enrolled(j, [a1])
r = cap(j, "s1", "keep the old API compatible", seq=1)
j.relink(a1, branch="feat/x-renamed")
check("a branch rename keeps the work's identity and direction",
      j.works_for_branch("loops", "feat/x-renamed") == [a1] and [m["text"] for m in j.messages(a1)] == ["keep the old API compatible"])
j.retire_work(a1)
a2 = j.create_work(repo="loops", branch="feat/x-renamed", todo_id="item-a", incarnation="i_a2")
check("a recreated branch/item gets a new work id that inherits nothing",
      a2 != a1 and j.messages(a2) == [] and j.work_for_todo("item-a", "i_a2") == a2 and j.work(a2)["revision"] == 0)
check("capture into retired work is refused", raises(wj.JournalError, lambda: cap(j, "s2", "more", seq=2, works=[a1])) is not None)

before = j.db.execute("SELECT count(*) FROM message").fetchone()[0]
check("an unenrolled conversation is not collected", isinstance(raises(wj.NotCollected, lambda: cap(j, "x1", "private", conv="other")), wj.NotCollected))
j.exclude("show", "private-chat")
check("an excluded conversation is not collected, even with an explicit target",
      raises(wj.NotCollected, lambda: cap(j, "p1", "secret", conv="private-chat", works=[a2])) is not None)
check("an excluded conversation can't be bound", raises(wj.NotCollected, lambda: j.bind("show", "private-chat", [a2], by="t")) is not None)
check("refused captures store nothing", j.db.execute("SELECT count(*) FROM message").fetchone()[0] == before)

# ---- immutability, duplicates, conflicts ----------------------------------------------------

j = fresh()
w = j.create_work(todo_id="t", incarnation="i_t")
enrolled(j, [w])
r1 = cap(j, "s1", "first", seq=1, target="session:abc")
dup = cap(j, "s1", "first", seq=1, target="session:abc")
check("a duplicate returns the original message and revision", dup["duplicate"] and dup["message_id"] == r1["message_id"] and dup["works"] == {w: 1})
check("a duplicate doesn't advance the revision or add delivery", j.work(w)["revision"] == 1 and len(j.outbox()) == 1)
check("one identity can't name different text", raises(wj.Conflict, lambda: cap(j, "s1", "edited", seq=1)) is not None)
check("one sequence number can't name two messages", raises(wj.Conflict, lambda: cap(j, "s9", "other", seq=1)) is not None)
for stmt in ("UPDATE message SET text = 'x'", "DELETE FROM message", "UPDATE work_revision SET revision = 9", "DELETE FROM message_work"):
    check(f"history is immutable: {stmt}", raises(sqlite3.DatabaseError, lambda: j.db.execute(stmt)) is not None)
agent = cap(j, "s2", "I'll start with the schema", seq=2, author="agent")
check("agent text is kept but never advances direction", j.work(w)["revision"] == 1 and all(m["text"] != "I'll start with the schema" for m in j.messages(w)))

# ---- source order, not arrival --------------------------------------------------------------

j = fresh()
w = j.create_work()
enrolled(j, [w])
cap(j, "m3", "also show last touch", seq=3)
late = cap(j, "m1", "keep compatibility with old callers", seq=1)
check("a delayed older message advances the revision", late["works"] == {w: 2} and j.work(w)["revision"] == 2)
lt = j.latest(w)
check("a delayed older message doesn't become the latest literal message", lt["order"] == "source" and lt["latest"]["text"] == "also show last touch")
check("direction is in source order, not arrival order", [m["source_seq"] for m in j.context(w)["direction"]] == [1, 3])

# ---- accumulated constraints vs the latest literal message ---------------------------------

j = fresh()
w = j.create_work()
other = j.create_work()
enrolled(j, [w])
c1 = cap(j, "a", "never change the old route's response shape", seq=1)
c2 = cap(j, "b", "also show last touch", seq=2)
ctx = j.context(w)
check("an earlier constraint survives a newer message", [m["text"] for m in ctx["direction"]] == ["never change the old route's response shape", "also show last touch"]
      and ctx["latest"]["text"] == "also show last touch")
c3 = cap(j, "c", "drop the compatibility requirement", seq=3, supersedes=[c1["message_id"]])
ctx = j.context(w)
check("only explicit user direction supersedes", [m["message_id"] for m in ctx["superseded"]] == [c1["message_id"]]
      and c1["message_id"] not in [m["message_id"] for m in ctx["direction"]] and ctx["revision"] == 3)
check("agent text can't supersede", raises(wj.JournalError, lambda: cap(j, "d", "summary", seq=4, author="agent", supersedes=[c2["message_id"]])) is not None)
j.bind("show", "c2", [other], by="t")
check("a message can't supersede another work's direction",
      raises(wj.JournalError, lambda: cap(j, "e", "forget that", conv="c2", seq=1, supersedes=[c2["message_id"]])) is not None)

# ---- task switching, multiple items, unassigned --------------------------------------------

j = fresh()
A, B = j.create_work(title="A"), j.create_work(title="B")
enrolled(j, [A])
first = cap(j, "m1", "do A this way", seq=1, target="session:1")
j.bind("show", "c1", [B], by="switch")
retry = cap(j, "m1", "do A this way", seq=1, target="session:1")
check("a retry after a task switch can't retarget the message", retry["duplicate"] and retry["works"] == {A: 1} and j.messages(B) == [])
cap(j, "m2", "now B", seq=2)
check("the switch binds later messages to the new work", [m["text"] for m in j.messages(B)] == ["now B"] and j.work(A)["revision"] == 1)
j.bind("show", "c1", [A, B], by="both")
both = cap(j, "m3", "rename both", seq=3)
check("a message bound to several items advances each one's revision", both["works"] == {A: 2, B: 2})
j.bind("show", "c1", [], by="unbind")
loose = cap(j, "m4", "hmm, which one?", seq=4)
check("an ambiguous message stays unassigned, never guessed", loose["works"] == {} and j.work(A)["revision"] == 2
      and [u["message_id"] for u in j.unassigned_for(A)] == [loose["message_id"]])
check("assigning it is a recorded decision that advances the revision", j.assign(loose["message_id"], A, by="phil") == 3
      and j.messages(A)[-1]["how"] == "assigned" and j.messages(A)[-1]["decided_by"] == "phil" and j.unassigned_for(A) == [])
check("a frozen binding can't be reassigned", raises(wj.Conflict, lambda: j.assign(first["message_id"], B, by="x")) is not None)

j.register_source("claude", adapter="test")
j.bind("claude", "sess-7", [A], by="t")
cap(j, "z1", "from another chat", seq=1, source="claude", conv="sess-7")
lt = j.latest(A)
check("two conversations get no invented total order", lt["latest"] is None and lt["order"] == "ambiguous" and len(lt["heads"]) == 2)


# Supersession is per work: superseding a shared instruction for A leaves B's intact.
j = fresh()
A, B = j.create_work(title="A"), j.create_work(title="B")
enrolled(j, [A, B])
shared = cap(j, "k1", "keep compatibility", seq=1)
revB = j.work(B)["revision"]
cap(j, "k2", "for A, drop compatibility", seq=2, works=[A], supersedes=[shared["message_id"]])
check("superseding a shared instruction for A keeps it in B's direction",
      [m["text"] for m in j.context(B)["direction"]] == ["keep compatibility"] and j.context(B)["superseded"] == [])
check("B's context didn't change, and neither did its revision", j.work(B)["revision"] == revB)
check("A's direction changed and its revision advanced",
      [m["text"] for m in j.context(A)["direction"]] == ["for A, drop compatibility"] and j.work(A)["revision"] == revB + 1)
before = {w: j.work(w)["revision"] for w in (A, B)}
cap(j, "k3", "drop it everywhere", seq=3, supersedes=[shared["message_id"]])
check("superseding where both carry it changes both, and both revisions advance",
      j.context(B)["direction"][-1]["text"] == "drop it everywhere" and "keep compatibility" not in [m["text"] for m in j.context(B)["direction"]]
      and all(j.work(w)["revision"] == before[w] + 1 for w in (A, B)))

# The binding is the one the source accepted the message under, even if capture first failed.
j = fresh()
A, B = j.create_work(), j.create_work()
enrolled(j, [A])
accepted = j.binding("show", "c1")
j.bind("show", "c1", [B], by="switch")
late = cap(j, "q1", "meant for A", seq=1, accepted_generation=accepted["generation"])
check("a retried capture keeps the binding accepted before a task switch", late["works"] == {A: 1} and j.messages(B) == [])
check("a generation that never existed is refused", raises(wj.JournalError, lambda: cap(j, "q2", "x", seq=2, accepted_generation=99)) is not None)

# Source semantics, sequence bounds, and bounded hole reporting.
j = fresh()
w = j.create_work()
enrolled(j, [w])
check("a source's ordering can't change under recorded sequence numbers",
      raises(wj.Conflict, lambda: j.register_source("show", adapter="test", ordering="none")) is not None)
check("absurd sequence numbers are refused", raises(wj.JournalError, lambda: cap(j, "big", "x", seq=2 ** 60)) is not None)
cap(j, "s1", "one", seq=1)
cap(j, "sbig", "far", seq=2 ** 52)
t0 = time.time()
cv = j.coverage(w)["conversations"][0]
check("a huge sparse gap is one range, counted without enumeration",
      cv["holes"] == [[2, 2 ** 52 - 1]] and cv["missing_count"] == 2 ** 52 - 2 and time.time() - t0 < 1.0, cv)
for k in range(3, 100, 2):
    cap(j, f"o{k}", "odd", seq=k)
cv = j.coverage(w)["conversations"][0]
check("hole listing is bounded", len(cv["holes"]) == 20 and cv["holes"][0] == [2, 2])

# context() reads one snapshot: a write landing mid-read can't mix revisions.
path_s = os.path.join(TMP, "snap.sqlite3")
js = wj.Journal(path_s)
ws = js.create_work()
enrolled(js, [ws])
cap(js, "a", "first", seq=1)
writer_j = wj.Journal(path_s)
orig = js.messages


def messages_then_write(work_id):
    out = orig(work_id)
    cap(writer_j, "b", "second", seq=2)
    return out


js.messages = messages_then_write
ctx = js.context(ws)
js.messages = orig
check("a packet's revision and direction come from one snapshot",
      ctx["revision"] == 1 and [m["text"] for m in ctx["direction"]] == ["first"] and ctx["latest"]["text"] == "first", ctx["revision"])
check("the concurrent write still landed", js.work(ws)["revision"] == 2)

# ---- coverage -------------------------------------------------------------------------------

j = fresh()
w = j.create_work()
check("work with no conversation has unknown coverage", j.coverage(w)["state"] == "unknown")
enrolled(j, [w])
cap(j, "1", "one", seq=1)
cap(j, "3", "three", seq=3)
check("no adapter claim: coverage unknown", j.coverage(w)["state"] == "unknown")
j.cover("show", "c1", 3)
cv = j.coverage(w)["conversations"][0]
check("a hole under the claim is a named gap", j.coverage(w)["state"] == "gaps" and cv["holes"] == [[2, 2]] and cv["missing_count"] == 1)
cap(j, "2", "two", seq=2)
check("filling the hole completes coverage", j.coverage(w)["state"] == "complete")
cap(j, "5", "five", seq=5)
check("a known later message beyond the claim exposes the hole before it", j.coverage(w)["conversations"][0]["holes"] == [[4, 4]])
j.cover("show", "c1", 2)
check("coverage claims only move forward", j.coverage(w)["conversations"][0]["covered_through"] == 3)
j.set_connected("show", False)
check("a disconnected adapter reads unknown, not quiet", j.coverage(w)["state"] == "unknown")
j2 = fresh()
w2 = j2.create_work()
enrolled(j2, [w2])
j2.cover("show", "c1", 30, start=21)
cap(j2, "21", "joined midway", seq=21)
check("collection that began midway counts from its start", j2.coverage(w2)["conversations"][0]["holes"] == [[22, 30]])

# ---- crash safety and the outbox ------------------------------------------------------------

clock = Clock()


def boom_at(stage):
    def fault(s):
        if s == stage:
            raise RuntimeError(f"crash at {s}")
    return fault


path = os.path.join(TMP, "crash.sqlite3")
setup = wj.Journal(path)
w = setup.create_work()
enrolled(setup, [w])
setup.close()
for stage in ("message", "revision", "outbox"):
    jj = wj.Journal(path, fault=boom_at(stage))
    raises(RuntimeError, lambda: cap(jj, f"x-{stage}", "lost?", target="session:1"))
    jj.close()
jj = wj.Journal(path)
check("a failure anywhere in capture leaves no partial record",
      jj.db.execute("SELECT count(*) FROM message").fetchone()[0] == 0 and jj.work(w)["revision"] == 0 and jj.outbox() == [])
jj.close()

# A real process records the message and exits before any dispatcher sees it.
code = f"""
import os, sys
sys.path.insert(0, {HERE!r})
from srv import workjournal as wj
j = wj.Journal({path!r})
j.capture(source="show", conversation="c1", source_message_id="real-1", text="survive me", source_seq=1, target="session:1")
os._exit(9)
"""
rc = subprocess.run([sys.executable, "-c", code]).returncode
jj = wj.Journal(path, clock=clock)
ob = jj.outbox(states=["pending"])
check("a process dying after capture leaves pending delivery to retry", rc == 9 and len(ob) == 1 and jj.work(w)["revision"] == 1)
leased = jj.lease("dispatcher-1", ttl=10)
check("a dispatcher leases it under the same message id", [x["message_id"] for x in leased] == [ob[0]["message_id"]] and leased[0]["text"] == "survive me")
check("nothing else can lease a live lease", jj.lease("dispatcher-2") == [])
clock.t += 11
re = jj.lease("dispatcher-2", ttl=10)
check("a dead dispatcher's lease expires and the row is retried", len(re) == 1 and re[0]["attempts"] == 2)
check("the dead dispatcher's late report is refused",
      raises(wj.Conflict, lambda: jj.settle(re[0]["outbox_id"], leased[0]["lease_token"], "delivered")) is not None and jj.outbox()[0]["state"] == "leased")
check("a report without a token is refused", raises(wj.Conflict, lambda: jj.settle(re[0]["outbox_id"], None, "delivered")) is not None)
jj.settle(re[0]["outbox_id"], re[0]["lease_token"], "failed", error="no pane", retry_in=5)
check("a failed send waits before retrying", jj.lease("d3") == [] and jj.outbox()[0]["state"] == "pending")
clock.t += 6
re = jj.lease("d3")
jj.settle(re[0]["outbox_id"], re[0]["lease_token"], "uncertain", error="no echo")
check("an unacknowledged hand-off stays uncertain, never re-sent as if unsent", jj.outbox()[0]["state"] == "uncertain" and jj.lease("d4") == [])
jj.close()


# Same dispatcher reclaims its own expired row; its first lease's delayed report must not settle the second.
clock2 = Clock()
jr = fresh(clock=clock2)
wr = jr.create_work()
enrolled(jr, [wr])
cap(jr, "r1", "deliver me", seq=1, target="session:1")
l1 = jr.lease("one-dispatcher", ttl=0)
l2 = jr.lease("one-dispatcher", ttl=60)
check("the same dispatcher can reclaim its own expired lease", len(l1) == 1 and len(l2) == 1 and l1[0]["lease_token"] != l2[0]["lease_token"])
check("the first lease's delayed report can't settle the reclaimed one",
      raises(wj.Conflict, lambda: jr.settle(l2[0]["outbox_id"], l1[0]["lease_token"], "delivered")) is not None and jr.outbox()[0]["state"] == "leased")
jr.settle(l2[0]["outbox_id"], l2[0]["lease_token"], "delivered")
check("the live lease settles", jr.outbox()[0]["state"] == "delivered")
check("a settled lease can't be reported twice", raises(wj.Conflict, lambda: jr.settle(l2[0]["outbox_id"], l2[0]["lease_token"], "failed")) is not None)

# ---- concurrency ----------------------------------------------------------------------------

cpath = os.path.join(TMP, "concurrent.sqlite3")
setup = wj.Journal(cpath)
w = setup.create_work()
enrolled(setup, [w])
setup.close()
writer = f"""
import sys
sys.path.insert(0, {HERE!r})
from srv import workjournal as wj
j = wj.Journal({cpath!r})
k = int(sys.argv[1])
for i in range(25):
    j.capture(source="show", conversation="c1", source_message_id=f"{{k}}-{{i}}", text=f"note {{k}} {{i}}", target="session:1")
    j.capture(source="show", conversation="c1", source_message_id=f"{{k}}-{{i}}", text=f"note {{k}} {{i}}", target="session:1")
"""
procs = [subprocess.Popen([sys.executable, "-c", writer, str(k)]) for k in range(8)]
codes = [p.wait() for p in procs]
jj = wj.Journal(cpath)
revs = [r["revision"] for r in jj.revisions(w)]
check("eight concurrent writers: every message kept, once", codes == [0] * 8 and jj.db.execute("SELECT count(*) FROM message").fetchone()[0] == 200)
check("revisions are contiguous with no lost or doubled update", revs == list(range(1, 201)) and jj.work(w)["revision"] == 200 and len(jj.outbox()) == 200)
jj.close()

print(f"\n{failures} failure(s)" if failures else "\nall passed")
sys.exit(1 if failures else 0)
