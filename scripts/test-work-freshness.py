#!/usr/bin/env python3
"""srv/workfresh.py: the viewer's per-item work freshness is bounded, read-only, and honest — new
direction after a qualified completion reads pending even while the tracker says done, unknown
coverage never reads answered, an open attempt is never "working", and the snapshot fingerprint
moves on journal-only changes. A temp tracker and journal; no live viewer state."""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = tempfile.mkdtemp(prefix="work-freshness-test-")
os.environ["CANOPY_TODO_DIR"] = os.path.join(TMP, "todo")
JPATH = os.path.join(TMP, "j", "journal.sqlite3")
os.environ["CANOPY_WORK_JOURNAL"] = JPATH
sys.path.insert(0, HERE)
from srv import todo, workdelivery as wd, workfresh as wf, workjournal as wj  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


def add(item_id, state=None):
    subprocess.run([sys.executable, os.path.join(HERE, "canopy-todo"), "add", item_id, "--kind", "build", "--area", "test",
                    "--why", "fixture", "--id", item_id], check=True, capture_output=True, env=os.environ)


def items():
    return {it["id"]: it for it in todo.all_items()}


add("item")
before = json.dumps(items(), sort_keys=True)
check("without a journal, items are untouched and nothing is created",
      json.dumps(wf.attach(items()), sort_keys=True) == before and not os.path.exists(os.path.dirname(JPATH)))
check("the fingerprint of an absent journal reads without creating it", wf.fingerprint() == (None, None) and not os.path.exists(JPATH))

j = wj.Journal(JPATH)
j.register_source("show", adapter="test")
W = j.work_for_todo("item", todo.read("item")["incarnation"], create=True)
add("legacy-free")
check("an item without journal work carries no work facts", "work" not in wf.attach(items())["legacy-free"])
check("an item with work but no captured direction is unknown, not answered",
      wf.attach(items())["item"]["work"]["state"] == "unknown" and wf.attach(items())["item"]["work"]["latest"] is None)

j.bind("show", "c1", [W], by="t")
first = j.capture(source="show", conversation="c1", source_message_id="1", text="keep the old route's response shape", source_seq=1)
j.capture(source="show", conversation="c1", source_message_id="2", text="also show last touch " + "x" * 3000, source_seq=2)
j.cover("show", "c1", 2)
f = wf.attach(items())["item"]["work"]
check("the latest literal message is projected, truncated and source-ordered",
      f["latest"]["text"].startswith("also show last touch") and f["latest"]["truncated"] and len(f["latest"]["text"]) == wf.TEXT_CAP
      and f["order"] == "source" and f["latest"]["seq"] == 2)
check("the earlier constraint is counted in force, not projected in full", f["in_force"] == 2 and "keep the old route" not in json.dumps(f))
check("captured direction with no completion is pending", f["state"] == "pending" and f["completion"] == "none" and f["coverage"] == "complete")

a = j.begin_attempt([W], worker="claude-say:abc", host="claude-say", managed=True)
pk = j.prepare(a["attempt_id"])
j.settle_receipt(j.open_receipt(pk["packet_id"], boundary="start"), "acknowledged")
j.report(W, "progress", "halfway", via="t", attempt_id=a["attempt_id"], packet_id=pk["packet_id"])
j.report(W, "completion", "done", via="t", attempt_id=a["attempt_id"], packet_id=pk["packet_id"])
closed = subprocess.run([sys.executable, os.path.join(HERE, "canopy-todo"), "set", "item", "state=done"], capture_output=True, text=True, env=os.environ)
completions = j.results(W, kind="completion")
check("closing the tracker item passes the journal: a legacy, uncited completion is recorded beside the qualified one",
      closed.returncode == 0 and "completion unverified" in closed.stderr
      and [(r["verdict"], r["via"]) for r in completions] == [("unverified", "canopy-todo set"), ("current", "t")], (closed.stderr, completions))
f = wf.attach(items())["item"]["work"]
check("a qualified completion of the current revision with complete coverage is answered, whatever a later uncited report says",
      f["state"] == "answered" and f["completion"] == "current" and f["answered_revision"] == 2
      and f["delivered"]["revision"] == 2 and f["delivered"]["state"] == "acknowledged")
check("the last dated progress is kept separate, with its basis", f["progress"]["text"] == "halfway" and f["progress"]["verdict_at_report"] == "current"
      and f["progress"]["delivered_revision"] == 2 and f["progress"]["basis"] == "current")
check("a host without a process lifecycle is unknown, not working", f["worker"]["state"] == "unknown" and f["worker"]["host"] == "claude-say")

j.capture(source="show", conversation="c1", source_message_id="3", text="one more thing", source_seq=3)
j.cover("show", "c1", 3)
it = wf.attach(items())["item"]
check("new direction after a qualified completion reads pending though the tracker says done; the qualified answer and the newest report both stay",
      it["state"] == "done" and it["work"]["state"] == "pending" and it["work"]["answered_revision"] == 2
      and it["work"]["completion"] == "unverified", it["work"])
check("the journal keeps both completions as written", [r["verdict"] for r in j.results(W, kind="completion")] == ["unverified", "current"])
check("progress against the older direction reads as older, its recorded verdict unchanged",
      it["work"]["progress"]["basis"] == "older" and it["work"]["progress"]["verdict_at_report"] == "current"
      and it["work"]["progress"]["delivered_revision"] == 2 and it["work"]["revision"] == 3)

j.capture(source="show", conversation="c1", source_message_id="5", text="five", source_seq=5)
f = wf.attach(items())["item"]["work"]
check("a capture gap makes freshness unknown", f["coverage"] == "gaps" and f["state"] == "unknown")
j.capture(source="show", conversation="c1", source_message_id="4", text="four", source_seq=4)
j.cover("show", "c1", 5)
a2 = j.begin_attempt([W], worker="claude-say:abc", host="claude-say", managed=True)
pk2 = j.prepare(a2["attempt_id"])
j.settle_receipt(j.open_receipt(pk2["packet_id"], boundary="turn"), "acknowledged")
j.report(W, "completion", "done again", via="t", attempt_id=a2["attempt_id"], packet_id=pk2["packet_id"])
f = wf.attach(items())["item"]["work"]
check("answered again once the new direction is delivered and completed", f["state"] == "answered")
check("progress from the superseded attempt reads as an earlier attempt's", f["progress"]["basis"] == "earlier-attempt")
j.set_connected("show", False)
f = wf.attach(items())["item"]["work"]
check("a disconnected source turns an answered item unknown, keeping the completion as history",
      f["state"] == "unknown" and f["coverage"] == "unknown" and f["completion"] == "current" and f["answered_revision"] == 5)
j.set_connected("show", True)

j.register_source("claude", adapter="test")
j.bind("claude", "s9", [W], by="t")
j.capture(source="claude", conversation="s9", source_message_id="x", text="from elsewhere", source_seq=1)
j.cover("claude", "s9", 1)
f = wf.attach(items())["item"]["work"]
check("direction from two conversations has no single latest message", f["latest"] is None and f["order"] == "ambiguous")

# The owned host's worker: observed running and ended, never inferred from the attempt record.
SID = "0f0e0d0c-1111-2222-3333-444455556666"
add("headless")
H = j.work_for_todo("headless", todo.read("headless")["incarnation"], create=True)
tg = wd.HeadlessClaudeTransport.register(j, SID, cwd=TMP, allowed_tools="Read")
j.bind("show", "h", [H], by="t")
j.capture(source="show", conversation="h", source_message_id="1", text="go", source_seq=1)
j.cover("show", "h", 1)
ah = j.begin_attempt([H], worker=tg, host="claude-headless", managed=True)
pkh = j.prepare(ah["attempt_id"])
rid = j.open_receipt(pkh["packet_id"], boundary="start")
j.settle_receipt(rid, "acknowledged")
j.record_turn(rid, worker=tg, pid=os.getpid(), start_token=wd._start_time(os.getpid()), input_uuid="u", log="/dev/null")
check("a turn whose process is alive reads running", wf.attach(items())["headless"]["work"]["worker"]["state"] == "running")
j.db.execute("UPDATE turn SET pid = 999999 WHERE receipt_id = ?", (rid,))
check("a turn whose process vanished reads ended, lost — without writing", wf.attach(items())["headless"]["work"]["worker"]["state"] == "ended"
      and wf.attach(items())["headless"]["work"]["worker"]["outcome"] == "lost" and j.turns(tg)[0]["outcome"] == "running")
j.end_turn(rid, "succeeded")
check("a finished turn reads ended, with its outcome", wf.attach(items())["headless"]["work"]["worker"]["outcome"] == "succeeded")

# The snapshot moves with the journal, and reading it writes nothing.
fp = wf.fingerprint()
mt = os.stat(JPATH).st_mtime_ns, os.path.getsize(JPATH + "-wal") if os.path.exists(JPATH + "-wal") else None
wf.attach(items())
check("projecting reads only", (os.stat(JPATH).st_mtime_ns, os.path.getsize(JPATH + "-wal") if os.path.exists(JPATH + "-wal") else None) == mt
      and wf.fingerprint() == fp)
j.capture(source="show", conversation="h", source_message_id="2", text="more", source_seq=2)
check("a journal-only change moves the fingerprint, with no tracker file touched", wf.fingerprint() != fp)
j.db.execute("UPDATE turn SET outcome = 'running', ended_at = NULL, pid = ?, start_token = ? WHERE receipt_id = ?",
             (os.getpid(), wd._start_time(os.getpid()), rid))
fp_alive = wf.fingerprint()
j.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
j.db.execute("UPDATE turn SET pid = 999999 WHERE receipt_id = ?", (rid,))
check("a crashed worker moves the fingerprint even when only liveness changed", wf.fingerprint()[2] != fp_alive[2])

# Worker state belongs to this work's own attempt, not to whatever the shared session runs next.
add("ta")
add("tb")
TA = j.work_for_todo("ta", todo.read("ta")["incarnation"], create=True)
TB = j.work_for_todo("tb", todo.read("tb")["incarnation"], create=True)
for conv, w in (("ta", TA), ("tb", TB)):
    j.bind("show", conv, [w], by="t")
    j.capture(source="show", conversation=conv, source_message_id="1", text=f"do {conv}", source_seq=1)
    j.cover("show", conv, 1)
SHARED = "claude-headless:0f0e0d0c-aaaa-2222-3333-444455556666"
real_alive = wd._alive
wd._alive = lambda pid, token: True


def turn_for(work_ids, end=None):
    a = j.begin_attempt(work_ids, worker=SHARED, host="claude-headless", managed=True)
    rid = j.open_receipt(j.prepare(a["attempt_id"])["packet_id"], boundary="start")
    j.settle_receipt(rid, "acknowledged")
    j.record_turn(rid, worker=SHARED, pid=os.getpid(), start_token="token", input_uuid=rid, log="/dev/null")
    if end:
        j.end_turn(rid, end)
    return a


turn_for([TA], end="succeeded")
turn_for([TB])
got = wf.attach(items())
check("after a task switch, A reads its own finished turn while B's runs on the same session",
      got["ta"]["work"]["worker"]["state"] == "ended" and got["ta"]["work"]["worker"]["outcome"] == "succeeded"
      and got["tb"]["work"]["worker"]["state"] == "running", (got["ta"]["work"]["worker"], got["tb"]["work"]["worker"]))
both = turn_for([TA, TB])
got = wf.attach(items())
check("one packet carrying both items shows both running", got["ta"]["work"]["worker"]["state"] == got["tb"]["work"]["worker"]["state"] == "running")
j.begin_attempt([TA], worker=SHARED, host="claude-headless", managed=True)
got = wf.attach(items())
check("a new attempt with no turn of its own inherits nobody's running state",
      got["ta"]["work"]["worker"]["state"] == "none" and got["tb"]["work"]["worker"]["state"] == "running")
wd._alive = lambda pid, token: None
check("an uninspectable turn of this attempt reads unknown", wf.attach(items())["tb"]["work"]["worker"]["state"] == "unknown")
wd._alive = lambda pid, token: False
got = wf.attach(items())
check("a vanished turn of this attempt reads ended, lost, and the read records nothing",
      got["tb"]["work"]["worker"] == {**got["tb"]["work"]["worker"], "state": "ended", "outcome": "lost"}
      and j.db.execute("SELECT count(*) FROM turn WHERE outcome = 'running'").fetchone()[0] >= 2)
wd._alive = real_alive

# One snapshot for every item: a capture landing mid-pass can't split the vector.
add("pa")
add("pb")
PA = j.work_for_todo("pa", todo.read("pa")["incarnation"], create=True)
PB = j.work_for_todo("pb", todo.read("pb")["incarnation"], create=True)
j.bind("show", "both", [PA, PB], by="t")
j.capture(source="show", conversation="both", source_message_id="1", text="first for both", source_seq=1)
j.cover("show", "both", 1)
orig_summary = wf.summary
landed = []


def summary_then_capture(jj, work_id):
    out = orig_summary(jj, work_id)
    if not landed:
        landed.append(True)
        other = wj.Journal(JPATH)
        other.capture(source="show", conversation="both", source_message_id="2", text="second for both", source_seq=2)
        other.cover("show", "both", 2)
    return out


wf.summary = summary_then_capture
got = wf.attach(items())
wf.summary = orig_summary
check("a capture landing mid-projection can't give two items different revisions of one message",
      got["pa"]["work"]["revision"] == got["pb"]["work"]["revision"] == 1 and landed)
check("the next projection sees it for both", wf.attach(items())["pa"]["work"]["revision"] == wf.attach(items())["pb"]["work"]["revision"] == 2)

# A journal that can't be read: tracker items still project, freshness says unavailable, nothing is written.
import shutil  # noqa: E402
bad_dir = os.path.join(TMP, "bad")
os.makedirs(bad_dir)
corrupt = os.path.join(bad_dir, "corrupt.sqlite3")
open(corrupt, "wb").write(b"this is not a database" * 100)
before_bytes = open(corrupt, "rb").read()
got = wf.attach(items(), path=corrupt)
check("a corrupt journal projects unavailable on linked items, and the tracker still projects",
      got["pa"]["work"]["state"] == "unavailable" and "DatabaseError" in got["pa"]["work"]["reason"] and got["legacy-free"]["title"] == "legacy-free")
check("its fingerprint reads without raising", wf.fingerprint(corrupt)[2].startswith("unreadable"))
check("and its bytes are untouched", open(corrupt, "rb").read() == before_bytes and not os.path.exists(corrupt + "-wal"))
old = os.path.join(bad_dir, "old.sqlite3")
shutil.copy(JPATH, old)
for ext in ("-wal", "-shm"):
    if os.path.exists(JPATH + ext):
        shutil.copy(JPATH + ext, old + ext)
oj = wj.Journal(old)
oj.db.execute("UPDATE meta SET value = '1' WHERE key = 'schema'")
oj.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
oj.close()
old_bytes = open(old, "rb").read()
got = wf.attach(items(), path=old)
check("an older schema projects unavailable rather than being migrated by a reader",
      got["pa"]["work"]["state"] == "unavailable" and "schema" in got["pa"]["work"]["reason"] and open(old, "rb").read() == old_bytes)

# A recreated record is a new subject: the old work's facts don't attach to it.
os.remove(os.path.join(os.environ["CANOPY_TODO_DIR"], "item.md"))
add("item")
check("a recreated record carries none of the old record's work facts", "work" not in wf.attach(items())["item"])

print(f"\n{failures} failure(s)" if failures else "\nall passed")
sys.exit(1 if failures else 0)
