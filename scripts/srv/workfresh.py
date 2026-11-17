"""srv/workfresh.py — each tracker item's work freshness, for the viewer's `todo` domain (DESIGN.md round 25).

A bounded summary per item whose live record (id + incarnation) has journal work, read through a
read-only journal connection — reading never creates or migrates the journal:

  latest       the latest literal user message (truncated), its source and times; null with
               `order: ambiguous` when direction spans conversations with no shared order
  in_force     how many messages are still direction; superseded and unassigned counts beside it
  revision     the work's current direction revision
  coverage     complete | gaps | unknown, as the capture sources report it now
  delivered    the newest delivery to the current attempt: its revision, boundary, state and time
  worker       the current attempt's host and its own newest turn as observed: none, running, ended
               (with how) or unknown — never another work's turn on the same session, and an open
               attempt record alone is never "working"
  progress     the last dated progress report (truncated), the revision and attempt generation it
               was delivered against, its verdict when recorded (immutable), and its basis now:
               current, older (direction moved since), earlier-attempt, or unverified
  completion   current | historical | stale | unverified | none, from the journal's own verdicts
  state        answered — a qualified completion answers this revision and coverage is complete now
               pending  — direction the latest qualified completion didn't answer, coverage complete
               unknown  — capture coverage isn't complete, so freshness can't be claimed

A journal that exists but can't be read (corrupt, an older schema, a read error) projects
`{"state": "unavailable", "reason"}` on every item that has an incarnation — never empty or green
facts — and the tracker itself still updates. No journal at all means capture isn't recorded: items
carry no `work`. Full direction travels only in managed turn packets, never in snapshots.
"""
import os
import sqlite3

from . import workdelivery, workjournal as wj

UNREADABLE = (wj.JournalError, sqlite3.DatabaseError, OSError)

TEXT_CAP = 2000
NOTE_CAP = 500


def fingerprint(path=None):
    """Moves when the journal changes (its file or write-ahead log) or when a turn it still records
    as running is observed to have stopped — a crashed host writes nothing, but its worker must not
    stay "running" in the snapshot."""
    path = path or wj.default_path()
    out = []
    for p in (path, path + "-wal"):
        try:
            st = os.stat(p)
            out.append((st.st_mtime_ns, st.st_size))
        except OSError:
            out.append(None)
    if out[0] is not None:
        try:
            j = wj.Journal(path, readonly=True)
            try:
                running = j.db.execute("SELECT receipt_id, pid, start_token FROM turn WHERE outcome = 'running'").fetchall()
                out.append(tuple((r["receipt_id"], workdelivery._alive(r["pid"], r["start_token"])) for r in running))
            finally:
                j.close()
        except UNREADABLE as e:
            out.append(f"unreadable: {type(e).__name__}")
    return tuple(out)


def _cap(text, n):
    if text is None:
        return None, False
    return (text[:n], True) if len(text) > n else (text, False)


def _latest(j, work_id):
    convs = j.db.execute("""SELECT DISTINCT m.conv_pk FROM message m JOIN message_work mw USING (message_id)
                            WHERE mw.work_id = ? AND m.author = 'user'""", (work_id,)).fetchall()
    if not convs:
        return None, "none"
    if len(convs) > 1:
        return None, "ambiguous"
    conv = convs[0][0]
    unordered = j.db.execute("""SELECT count(*) FROM message m JOIN message_work mw USING (message_id)
                                WHERE mw.work_id = ? AND m.author = 'user' AND m.source_seq IS NULL""", (work_id,)).fetchone()[0]
    total = j.db.execute("SELECT count(*) FROM message_work mw JOIN message m USING (message_id) WHERE mw.work_id = ? AND m.author = 'user'",
                         (work_id,)).fetchone()[0]
    if unordered and total > 1:
        return None, "ambiguous"
    m = j.db.execute("""SELECT m.*, c.source_id, c.conversation_id FROM message m JOIN message_work mw USING (message_id)
                        JOIN conversation c USING (conv_pk) WHERE mw.work_id = ? AND m.author = 'user' AND m.conv_pk = ?
                        ORDER BY m.source_seq DESC LIMIT 1""", (work_id, conv)).fetchone()
    text, cut = _cap(m["text"], TEXT_CAP)
    return {"message_id": m["message_id"], "text": text, "truncated": cut, "source": m["source_id"],
            "conversation": m["conversation_id"], "seq": m["source_seq"], "source_time": m["source_time"],
            "received_at": m["received_at"]}, "source"


def _attempt_turn(j, attempt_id):
    """The worker as observed for this attempt only — its own newest turn, never another work's turn
    on the same session: none (no turn yet in this attempt), running, unknown (identity can't be
    checked), or ended with the turn's recorded outcome (lost if its process vanished unrecorded).
    Reads only."""
    t = j.db.execute("""SELECT t.* FROM turn t JOIN receipt r USING (receipt_id) WHERE r.attempt_id = ?
                        ORDER BY t.rowid DESC LIMIT 1""", (attempt_id,)).fetchone()
    if t is None:
        return {"state": "none"}
    if t["outcome"] == "running":
        alive = workdelivery._alive(t["pid"], t["start_token"])
        if alive:
            return {"state": "running"}
        if alive is None:
            return {"state": "unknown", "why": "the turn's process can't be identified"}
        return {"state": "ended", "outcome": "lost"}
    return {"state": "ended", "outcome": t["outcome"], "ended_at": t["ended_at"]}


def summary(j, work_id):
    """One work's freshness, from one read snapshot."""
    with j.snapshot() as db:
        st = j.status(work_id)
        latest, order = _latest(j, work_id)
        counts = db.execute("""SELECT
              SUM(CASE WHEN NOT EXISTS (SELECT 1 FROM supersession s WHERE s.supersedes = m.message_id AND s.work_id = mw.work_id) THEN 1 ELSE 0 END),
              SUM(CASE WHEN EXISTS (SELECT 1 FROM supersession s WHERE s.supersedes = m.message_id AND s.work_id = mw.work_id) THEN 1 ELSE 0 END)
            FROM message m JOIN message_work mw USING (message_id) WHERE mw.work_id = ? AND m.author = 'user'""", (work_id,)).fetchone()
        unassigned = db.execute("""SELECT count(*) FROM message m WHERE m.author = 'user'
              AND NOT EXISTS (SELECT 1 FROM message_work mw WHERE mw.message_id = m.message_id)
              AND m.conv_pk IN (SELECT conv_pk FROM binding_work WHERE work_id = ?)""", (work_id,)).fetchone()[0]
        coverage = j._coverage(work_id)["state"]
        att = st["attempt"]
        worker = None
        delivered = None
        if att:
            if att["host"] == workdelivery.HeadlessClaudeTransport.host:
                observed = _attempt_turn(j, att["attempt_id"])
            else:
                observed = {"state": "unknown", "why": f"{att['host']} reports no process lifecycle"}
            worker = {"host": att["host"], "managed": att["managed"], "generation": att["generation"], "started_at": att["started_at"],
                      "attempt_ended_at": att["ended_at"], **{k: v for k, v in observed.items() if k in ("state", "outcome", "ended_at", "why")}}
            last = att["last_delivery"]
            if last:
                delivered = {"revision": last["revision"], "boundary": last["boundary"], "state": last["state"],
                             "at": last["settled_at"] or last["opened_at"], "acknowledged_revision": att["acknowledged_revision"]}
        progress = None
        p = st["last_progress"]
        if p:
            text, cut = _cap(p["text"], NOTE_CAP)
            if p["verdict"] == "unverified" or p["delivered_revision"] is None:
                basis = "unverified"
            elif att is None or p["generation"] != att["generation"] or p["attempt_id"] != att["attempt_id"]:
                basis = "earlier-attempt"
            elif p["delivered_revision"] != st["revision"]:
                basis = "older"
            else:
                basis = "current" if p["verdict"] == "current" else p["verdict"]
            progress = {"text": text, "truncated": cut, "at": p["recorded_at"], "verdict_at_report": p["verdict"],
                        "delivered_revision": p["delivered_revision"], "generation": p["generation"], "basis": basis}
        qualified = st["qualified_completion"]
        answered_revision = qualified["delivered_revision"] if qualified else None
        if coverage != "complete":
            state = "unknown"
        elif st["completion"] == "current":
            state = "answered"
        else:
            state = "pending"
        return {"work_id": work_id, "revision": st["revision"], "latest": latest, "order": order,
                "in_force": counts[0] or 0, "superseded": counts[1] or 0, "unassigned": unassigned, "coverage": coverage,
                "delivered": delivered, "worker": worker, "progress": progress, "completion": st["completion"],
                "answered_revision": answered_revision, "state": state}


def attach(items, path=None):
    """Adds `work` to each tracker item (a {id: item} dict) whose live record has journal work.
    Items without it are left untouched: their capture is not recorded."""
    try:
        j = wj.Journal(path, readonly=True)
    except wj.Absent:
        return items
    except UNREADABLE as e:
        return _unavailable(items, e)
    try:
        with j.snapshot():
            found = {}
            for item in items.values():
                inc = item.get("incarnation")
                if inc:
                    w = j.work_for_todo(item["id"], inc)
                    if w:
                        found[item["id"]] = summary(j, w)
    except UNREADABLE as e:
        return _unavailable(items, e)
    finally:
        j.close()
    for item_id, work in found.items():
        items[item_id]["work"] = work
    return items


def _unavailable(items, error):
    reason = f"work journal unreadable: {type(error).__name__}: {error}"[:300]
    for item in items.values():
        if item.get("incarnation"):
            item["work"] = {"state": "unavailable", "reason": reason}
    return items
