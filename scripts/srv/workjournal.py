"""srv/workjournal.py — the one canonical record of human work input (DESIGN.md round 25).

A SQLite journal, every write one `BEGIN IMMEDIATE` transaction, so concurrent writers serialize
instead of overwriting each other. What it owns:

  work            stable ids ('w_…', never reused). The tracker item, repository, forest and branch
                  are link metadata: renaming a branch relinks, deleting it retires the work, and a
                  recreated branch gets a new work id that inherits nothing.
  conversation    a source's conversation, collected only once enrolled by an explicit binding.
                  Its binding — the set of work items its messages belong to — has generations;
                  launching or switching work starts a new one. An excluded conversation is never
                  collected, even with an explicit target.
  message         immutable literal input (update/delete abort), identified by
                  (source, conversation, source message id). Source order (`source_seq`), source time
                  and received time are separate columns: arrival never decides chronology.
                  The binding in force at submission is frozen with the message; a retry after
                  a task switch returns the original row and cannot retarget it.
  work_revision   append-only; each newly captured piece of direction for a work advances its
                  revision by one in the capture transaction. Revisions order knowledge for
                  concurrency checks, not human chronology: a delayed older message advances
                  the revision without becoming the latest literal message.
  coverage        an adapter's per-conversation claim of every sequence number it has offered;
                  holes stay visible and an unclaimed or disconnected source reads "unknown".
  outbox          pending delivery, written in the same transaction as capture, so a crash after
                  capture leaves a row to retry under the same message id; a duplicate capture
                  adds nothing.

The latest literal message and the accumulated direction are separate projections: an earlier
constraint survives a newer message unless a user message explicitly supersedes it.

Path: $CANOPY_WORK_JOURNAL, else ~/.local/state/canopy/work-journal.sqlite3. Stdlib only.
"""
import contextlib
import datetime
import hashlib
import json
import os
import sqlite3
import time
import uuid

SCHEMA_VERSION = 1
AUTHORS = ("user", "agent", "system")
ORDERINGS = ("sequence", "none")
MAX_SEQ = 2 ** 53


def default_path():
    return os.environ.get("CANOPY_WORK_JOURNAL") or os.path.expanduser("~/.local/state/canopy/work-journal.sqlite3")


class JournalError(ValueError):
    """A request the journal refuses; nothing was written."""


class NotCollected(JournalError):
    """The conversation was never enrolled, or is excluded: its messages are not ours to keep."""


class Conflict(JournalError):
    """An identity already names different content (immutable messages, unique sequence numbers)."""


SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;

CREATE TABLE IF NOT EXISTS work (
  work_id    TEXT PRIMARY KEY,
  todo_id    TEXT,
  repo       TEXT,
  project    TEXT,
  branch     TEXT,
  title      TEXT,
  revision   INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  retired_at TEXT
) STRICT;
CREATE UNIQUE INDEX IF NOT EXISTS work_live_todo ON work(todo_id) WHERE retired_at IS NULL AND todo_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS work_branch ON work(repo, branch);

CREATE TABLE IF NOT EXISTS source (
  source_id  TEXT PRIMARY KEY,
  adapter    TEXT NOT NULL,
  ordering   TEXT NOT NULL CHECK (ordering IN ('sequence', 'none')),
  connected  INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS conversation (
  conv_pk            INTEGER PRIMARY KEY,
  source_id          TEXT NOT NULL REFERENCES source(source_id),
  conversation_id    TEXT NOT NULL,
  excluded           INTEGER NOT NULL DEFAULT 0,
  binding_generation INTEGER NOT NULL DEFAULT 0,
  collect_from       INTEGER,
  covered_through    INTEGER,
  covered_at         TEXT,
  UNIQUE (source_id, conversation_id)
) STRICT;

CREATE TABLE IF NOT EXISTS binding (
  conv_pk    INTEGER NOT NULL REFERENCES conversation(conv_pk),
  generation INTEGER NOT NULL,
  bound_at   TEXT NOT NULL,
  bound_by   TEXT NOT NULL,
  PRIMARY KEY (conv_pk, generation)
) STRICT;
CREATE TABLE IF NOT EXISTS binding_work (
  conv_pk    INTEGER NOT NULL,
  generation INTEGER NOT NULL,
  work_id    TEXT NOT NULL REFERENCES work(work_id),
  PRIMARY KEY (conv_pk, generation, work_id),
  FOREIGN KEY (conv_pk, generation) REFERENCES binding(conv_pk, generation)
) STRICT;

CREATE TABLE IF NOT EXISTS message (
  message_id         TEXT PRIMARY KEY,
  conv_pk            INTEGER NOT NULL REFERENCES conversation(conv_pk),
  source_message_id  TEXT NOT NULL,
  source_seq         INTEGER,
  source_time        TEXT,
  received_at        TEXT NOT NULL,
  author             TEXT NOT NULL CHECK (author IN ('user', 'agent', 'system')),
  text               TEXT NOT NULL,
  digest             TEXT NOT NULL,
  binding_generation INTEGER NOT NULL,
  UNIQUE (conv_pk, source_message_id),
  UNIQUE (conv_pk, source_seq)
) STRICT;
CREATE TABLE IF NOT EXISTS message_work (
  message_id TEXT NOT NULL REFERENCES message(message_id),
  work_id    TEXT NOT NULL REFERENCES work(work_id),
  how        TEXT NOT NULL CHECK (how IN ('binding', 'explicit', 'assigned')),
  decided_by TEXT,
  decided_at TEXT NOT NULL,
  PRIMARY KEY (message_id, work_id)
) STRICT;
CREATE INDEX IF NOT EXISTS message_work_by_work ON message_work(work_id);
CREATE TABLE IF NOT EXISTS supersession (
  message_id TEXT NOT NULL REFERENCES message(message_id),
  supersedes TEXT NOT NULL REFERENCES message(message_id),
  work_id    TEXT NOT NULL REFERENCES work(work_id),
  PRIMARY KEY (message_id, supersedes, work_id)
) STRICT;

CREATE TABLE IF NOT EXISTS work_revision (
  work_id    TEXT NOT NULL REFERENCES work(work_id),
  revision   INTEGER NOT NULL,
  cause      TEXT NOT NULL,
  message_id TEXT REFERENCES message(message_id),
  at         TEXT NOT NULL,
  PRIMARY KEY (work_id, revision)
) STRICT;

CREATE TABLE IF NOT EXISTS outbox (
  outbox_id   INTEGER PRIMARY KEY,
  message_id  TEXT NOT NULL REFERENCES message(message_id),
  target      TEXT NOT NULL,
  state       TEXT NOT NULL CHECK (state IN ('pending', 'leased', 'delivered', 'uncertain', 'abandoned')),
  attempts    INTEGER NOT NULL DEFAULT 0,
  lease_owner TEXT,
  lease_token TEXT,
  lease_until REAL,
  not_before  REAL NOT NULL DEFAULT 0,
  last_error  TEXT,
  created_at  TEXT NOT NULL,
  settled_at  TEXT,
  UNIQUE (message_id, target)
) STRICT;
CREATE INDEX IF NOT EXISTS outbox_due ON outbox(state, not_before);
"""

# Written history is immutable: the journal appends, it never edits what was said or decided.
IMMUTABLE = ("message", "message_work", "supersession", "work_revision", "binding", "binding_work")
TRIGGERS = "".join(
    f"""
CREATE TRIGGER IF NOT EXISTS {t}_no_update BEFORE UPDATE ON {t} BEGIN SELECT RAISE(ABORT, '{t} is immutable'); END;
CREATE TRIGGER IF NOT EXISTS {t}_no_delete BEFORE DELETE ON {t} BEGIN SELECT RAISE(ABORT, '{t} is immutable'); END;"""
    for t in IMMUTABLE)


def _iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def digest(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class Journal:
    """One connection to the journal. `clock` returns epoch seconds; tests pass a fake one.
    `fault` is a test hook called with a stage name inside write transactions."""

    def __init__(self, path=None, clock=time.time, fault=None):
        self.path = path or default_path()
        if self.path != ":memory:":
            os.makedirs(os.path.dirname(os.path.abspath(self.path)), exist_ok=True)
        self.clock = clock
        self.fault = fault or (lambda stage: None)
        self.db = sqlite3.connect(self.path, timeout=30, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys = ON")
        self.db.execute("PRAGMA busy_timeout = 30000")
        if self.path != ":memory:":
            self.db.execute("PRAGMA journal_mode = WAL")
            self.db.execute("PRAGMA synchronous = FULL")
        with self.tx():
            for stmt in _statements(SCHEMA + TRIGGERS):
                self.db.execute(stmt)
            row = self.db.execute("SELECT value FROM meta WHERE key = 'schema'").fetchone()
            if row is None:
                self.db.execute("INSERT INTO meta VALUES ('schema', ?)", (str(SCHEMA_VERSION),))
            elif int(row["value"]) > SCHEMA_VERSION:
                raise JournalError(f"journal schema {row['value']} is newer than this code ({SCHEMA_VERSION})")

    def close(self):
        self.db.close()

    def now(self):
        return _iso(self.clock())

    @contextlib.contextmanager
    def snapshot(self):
        """One consistent read across several queries (re-entrant; a no-op inside a write)."""
        if self.db.in_transaction:
            yield self.db
            return
        self.db.execute("BEGIN DEFERRED")
        try:
            yield self.db
        finally:
            self.db.execute("COMMIT")

    @contextlib.contextmanager
    def tx(self):
        """One write transaction, taken before reading so no other writer interleaves."""
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield self.db
        except BaseException:
            self.db.execute("ROLLBACK")
            raise
        self.db.execute("COMMIT")

    # ---- work identities -------------------------------------------------------------------

    def create_work(self, *, todo_id=None, repo=None, project=None, branch=None, title=None):
        work_id = "w_" + uuid.uuid4().hex
        with self.tx() as db:
            try:
                db.execute("INSERT INTO work (work_id, todo_id, repo, project, branch, title, created_at) VALUES (?,?,?,?,?,?,?)",
                           (work_id, todo_id, repo, project, branch, title, self.now()))
            except sqlite3.IntegrityError:
                raise Conflict(f"tracker item {todo_id} already has live work") from None
        return work_id

    def work_for_todo(self, todo_id, *, create=False, **links):
        """The live work linked to a tracker item; with create, makes it on first use."""
        row = self.db.execute("SELECT work_id FROM work WHERE todo_id = ? AND retired_at IS NULL", (todo_id,)).fetchone()
        if row:
            return row["work_id"]
        if not create:
            return None
        try:
            return self.create_work(todo_id=todo_id, **links)
        except Conflict:   # a concurrent first use made it
            return self.work_for_todo(todo_id)

    def works_for_branch(self, repo, branch):
        """Live work linked to a branch. Both names are required: equal branch names in two
        repositories are different subjects."""
        if not repo or not branch:
            raise JournalError("a branch is only a subject with its repository")
        return [r["work_id"] for r in self.db.execute(
            "SELECT work_id FROM work WHERE repo = ? AND branch = ? AND retired_at IS NULL ORDER BY created_at, work_id", (repo, branch))]

    def relink(self, work_id, **links):
        """Updates link metadata (a branch rename, a new forest). Identity and history stay."""
        allowed = {"todo_id", "repo", "project", "branch", "title"}
        bad = set(links) - allowed
        if bad:
            raise JournalError(f"not link metadata: {', '.join(sorted(bad))}")
        with self.tx() as db:
            self._live_work(db, work_id)
            for k, v in links.items():
                db.execute(f"UPDATE work SET {k} = ? WHERE work_id = ?", (v, work_id))

    def retire_work(self, work_id):
        """Ends a work identity (its branch was deleted, its item dropped). Never reused."""
        with self.tx() as db:
            self._live_work(db, work_id)
            db.execute("UPDATE work SET retired_at = ? WHERE work_id = ?", (self.now(), work_id))

    def work(self, work_id):
        row = self.db.execute("SELECT * FROM work WHERE work_id = ?", (work_id,)).fetchone()
        return dict(row) if row else None

    @staticmethod
    def _live_work(db, work_id):
        row = db.execute("SELECT retired_at FROM work WHERE work_id = ?", (work_id,)).fetchone()
        if row is None:
            raise JournalError(f"no work {work_id}")
        if row["retired_at"]:
            raise JournalError(f"work {work_id} was retired at {row['retired_at']}")

    # ---- sources, conversations, bindings ---------------------------------------------------

    def register_source(self, source_id, *, adapter, ordering="sequence"):
        if ordering not in ORDERINGS:
            raise JournalError(f"ordering {ordering!r} is not one of {', '.join(ORDERINGS)}")
        with self.tx() as db:
            old = db.execute("SELECT ordering FROM source WHERE source_id = ?", (source_id,)).fetchone()
            if old is not None and old["ordering"] != ordering:
                raise Conflict(f"source {source_id} orders by {old['ordering']}; its sequence numbers would change meaning")
            db.execute("""INSERT INTO source (source_id, adapter, ordering, connected, updated_at) VALUES (?,?,?,1,?)
                          ON CONFLICT (source_id) DO UPDATE SET adapter = excluded.adapter,
                          connected = 1, updated_at = excluded.updated_at""", (source_id, adapter, ordering, self.now()))

    def set_connected(self, source_id, connected):
        """An adapter disconnecting leaves its coverage unknown from then on, never 'quiet'."""
        with self.tx() as db:
            if db.execute("UPDATE source SET connected = ?, updated_at = ? WHERE source_id = ?",
                          (1 if connected else 0, self.now(), source_id)).rowcount == 0:
                raise JournalError(f"no source {source_id}")

    def _conversation(self, db, source_id, conversation_id, *, create=False):
        row = db.execute("SELECT * FROM conversation WHERE source_id = ? AND conversation_id = ?", (source_id, conversation_id)).fetchone()
        if row or not create:
            return row
        if not db.execute("SELECT 1 FROM source WHERE source_id = ?", (source_id,)).fetchone():
            raise JournalError(f"no source {source_id} — register its adapter first")
        db.execute("INSERT INTO conversation (source_id, conversation_id) VALUES (?, ?)", (source_id, conversation_id))
        return db.execute("SELECT * FROM conversation WHERE source_id = ? AND conversation_id = ?", (source_id, conversation_id)).fetchone()

    def bind(self, source_id, conversation_id, work_ids, *, by):
        """Starts a new binding generation: launching or switching work. An empty list unbinds
        (later messages are captured unassigned, never guessed). Returns the generation."""
        with self.tx() as db:
            conv = self._conversation(db, source_id, conversation_id, create=True)
            if conv["excluded"]:
                raise NotCollected(f"{source_id}/{conversation_id} is excluded from collection")
            for w in work_ids:
                self._live_work(db, w)
            gen = conv["binding_generation"] + 1
            now = self.now()
            db.execute("INSERT INTO binding VALUES (?,?,?,?)", (conv["conv_pk"], gen, now, by))
            for w in dict.fromkeys(work_ids):
                db.execute("INSERT INTO binding_work VALUES (?,?,?)", (conv["conv_pk"], gen, w))
            db.execute("UPDATE conversation SET binding_generation = ? WHERE conv_pk = ?", (gen, conv["conv_pk"]))
            return gen

    def exclude(self, source_id, conversation_id):
        """Marks a conversation private/unrelated: nothing from it is ever captured."""
        with self.tx() as db:
            conv = self._conversation(db, source_id, conversation_id, create=True)
            db.execute("UPDATE conversation SET excluded = 1 WHERE conv_pk = ?", (conv["conv_pk"],))

    def binding(self, source_id, conversation_id):
        """The binding in force now: {generation, works}. An ingress reads this when it accepts a
        message and passes the generation to capture, so a failed first capture followed by a
        task switch still records the binding the human submitted under."""
        with self.snapshot() as db:
            conv = self._conversation(db, source_id, conversation_id)
            if conv is None:
                return None
            return {"generation": conv["binding_generation"], "excluded": bool(conv["excluded"]),
                    "works": self._generation_works(db, conv["conv_pk"], conv["binding_generation"])}

    def bound_works(self, source_id, conversation_id):
        b = self.binding(source_id, conversation_id)
        return b["works"] if b else []

    @staticmethod
    def _generation_works(db, conv_pk, generation):
        return [r["work_id"] for r in db.execute(
            "SELECT work_id FROM binding_work WHERE conv_pk = ? AND generation = ? ORDER BY work_id", (conv_pk, generation))]

    # ---- capture ---------------------------------------------------------------------------

    def capture(self, *, source, conversation, source_message_id, text, author="user", source_seq=None,
                source_time=None, works=None, supersedes=(), target=None, accepted_generation=None):
        """Durably records one message, before anything accepts it for delivery.

        `works` names the target explicitly; otherwise the binding generation the source accepted
        the message under (`accepted_generation`, from `binding()`; default: the one in force
        now) is frozen with it. Returns {message_id, duplicate, works: {work_id: revision}, outbox_id}.
        A repeated capture of the same identity and text is a duplicate: it returns the original
        row (original binding, original revisions) and writes nothing. Raises NotCollected for
        an unenrolled or excluded conversation and Conflict for an identity that names other text."""
        if author not in AUTHORS:
            raise JournalError(f"author {author!r} is not one of {', '.join(AUTHORS)}")
        if not isinstance(text, str) or not text.strip():
            raise JournalError("a message needs text")
        if source_seq is not None and (not isinstance(source_seq, int) or isinstance(source_seq, bool) or not 1 <= source_seq < MAX_SEQ):
            raise JournalError(f"source_seq is an integer from 1 below {MAX_SEQ}")
        d = digest(text)
        with self.tx() as db:
            conv = self._conversation(db, source, conversation)
            if conv is None:
                raise NotCollected(f"{source}/{conversation} is not enrolled — bind it to work first")
            if conv["excluded"]:
                raise NotCollected(f"{source}/{conversation} is excluded from collection")
            old = db.execute("SELECT * FROM message WHERE conv_pk = ? AND source_message_id = ?",
                             (conv["conv_pk"], source_message_id)).fetchone()
            if old is not None:
                if old["digest"] != d or old["author"] != author or (source_seq is not None and old["source_seq"] != source_seq):
                    raise Conflict(f"message {source_message_id} was already captured with different content")
                return self._captured(db, old["message_id"], duplicate=True, target=target)
            if source_seq is not None and db.execute("SELECT 1 FROM message WHERE conv_pk = ? AND source_seq = ?",
                                                     (conv["conv_pk"], source_seq)).fetchone():
                raise Conflict(f"sequence {source_seq} in {source}/{conversation} already names another message")
            generation = conv["binding_generation"] if accepted_generation is None else accepted_generation
            if not isinstance(generation, int) or not 0 <= generation <= conv["binding_generation"]:
                raise JournalError(f"{source}/{conversation} has no binding generation {generation!r}")
            if works is None:
                how = "binding"
                targets = self._generation_works(db, conv["conv_pk"], generation)
            else:
                how = "explicit"
                targets = list(dict.fromkeys(works))
            for w in targets:
                self._live_work(db, w)
            message_id = "m_" + uuid.uuid4().hex
            now = self.now()
            db.execute("""INSERT INTO message (message_id, conv_pk, source_message_id, source_seq, source_time, received_at,
                          author, text, digest, binding_generation) VALUES (?,?,?,?,?,?,?,?,?,?)""",
                       (message_id, conv["conv_pk"], source_message_id, source_seq, source_time, now, author, text, d,
                        generation))
            self.fault("message")
            for w in targets:
                db.execute("INSERT INTO message_work VALUES (?,?,?,?,?)", (message_id, w, how, None, now))
            for s in dict.fromkeys(supersedes):
                for w in self._superseded_in(db, s, author, targets):
                    db.execute("INSERT INTO supersession VALUES (?,?,?)", (message_id, s, w))
            if author == "user":
                for w in targets:
                    self._advance(db, w, "message", message_id, now)
            self.fault("revision")
            if target:
                db.execute("INSERT INTO outbox (message_id, target, state, created_at) VALUES (?,?,'pending',?)",
                           (message_id, target, now))
            self.fault("outbox")
            return self._captured(db, message_id, duplicate=False, target=target)

    @staticmethod
    def _superseded_in(db, old_id, author, targets):
        """The works where `old_id` stops being direction: only those both messages belong to.
        Each of them advances its revision with the superseding message; any other work that
        carries `old_id` keeps it."""
        if author != "user":
            raise JournalError("only user direction can supersede a message")
        held = {r["work_id"] for r in db.execute("SELECT work_id FROM message_work WHERE message_id = ?", (old_id,))}
        if not held:
            raise JournalError(f"{old_id} is not captured direction for any work")
        shared = sorted(held & set(targets))
        if not shared:
            raise JournalError(f"{old_id} belongs to other work; a message supersedes only within its own")
        return shared

    def _advance(self, db, work_id, cause, message_id, now):
        rev = db.execute("UPDATE work SET revision = revision + 1 WHERE work_id = ? RETURNING revision", (work_id,)).fetchone()["revision"]
        db.execute("INSERT INTO work_revision VALUES (?,?,?,?,?)", (work_id, rev, cause, message_id, now))
        return rev

    def _captured(self, db, message_id, *, duplicate, target):
        revs = {r["work_id"]: r["revision"] for r in db.execute(
            "SELECT work_id, revision FROM work_revision WHERE message_id = ? ORDER BY work_id", (message_id,))}
        works = [r["work_id"] for r in db.execute("SELECT work_id FROM message_work WHERE message_id = ? ORDER BY work_id", (message_id,))]
        ob = db.execute("SELECT outbox_id FROM outbox WHERE message_id = ? AND target = ?", (message_id, target)).fetchone() if target else None
        return {"message_id": message_id, "duplicate": duplicate, "works": {w: revs.get(w) for w in works},
                "outbox_id": ob["outbox_id"] if ob else None}

    def assign(self, message_id, work_id, *, by):
        """A deliberate decision placing an unassigned message on a work item. The message's
        submission binding is untouched; this records a separate, attributed decision."""
        with self.tx() as db:
            msg = db.execute("SELECT author FROM message WHERE message_id = ?", (message_id,)).fetchone()
            if msg is None:
                raise JournalError(f"no message {message_id}")
            if db.execute("SELECT 1 FROM message_work WHERE message_id = ?", (message_id,)).fetchone():
                raise Conflict(f"{message_id} already belongs to work; its binding is frozen")
            self._live_work(db, work_id)
            now = self.now()
            db.execute("INSERT INTO message_work VALUES (?,?,'assigned',?,?)", (message_id, work_id, by, now))
            return self._advance(db, work_id, "assignment", message_id, now) if msg["author"] == "user" else None

    # ---- coverage --------------------------------------------------------------------------

    def cover(self, source_id, conversation_id, through_seq, *, start=1):
        """The adapter's claim: it has offered every message of this conversation numbered from
        `start` (fixed by the first claim: collection began there) up to `through_seq`.
        Claims only move forward."""
        with self.tx() as db:
            conv = self._conversation(db, source_id, conversation_id)
            if conv is None:
                raise NotCollected(f"{source_id}/{conversation_id} is not enrolled")
            db.execute("""UPDATE conversation SET collect_from = COALESCE(collect_from, ?),
                          covered_through = MAX(COALESCE(covered_through, 0), ?), covered_at = ?
                          WHERE conv_pk = ?""", (start, through_seq, self.now(), conv["conv_pk"]))

    def coverage(self, work_id):
        """Per conversation that ever carried this work's direction (or is bound to it now):
        state complete | gaps | unknown, with the holes named. A work with no conversations is
        unknown — absence of messages proves nothing."""
        with self.snapshot():
            return self._coverage(work_id)

    def _coverage(self, work_id):
        convs = self.db.execute("""
            SELECT DISTINCT c.*, s.ordering, s.connected FROM conversation c JOIN source s USING (source_id)
            WHERE c.conv_pk IN (SELECT conv_pk FROM binding_work WHERE work_id = :w
                                UNION SELECT m.conv_pk FROM message m JOIN message_work mw USING (message_id) WHERE mw.work_id = :w)
            ORDER BY c.source_id, c.conversation_id""", {"w": work_id}).fetchall()
        out = []
        for c in convs:
            last = self.db.execute("SELECT MIN(source_seq) AS lo, MAX(source_seq) AS hi FROM message WHERE conv_pk = ?", (c["conv_pk"],)).fetchone()
            first = c["collect_from"] if c["collect_from"] is not None else (last["lo"] or 1)
            upto = max(c["covered_through"] or 0, last["hi"] or 0)
            holes, missing_count = self._holes(c["conv_pk"], first, upto)
            if c["ordering"] != "sequence" or not c["connected"] or c["covered_through"] is None:
                state = "unknown"
            elif missing_count:
                state = "gaps"
            else:
                state = "complete"
            out.append({"source": c["source_id"], "conversation": c["conversation_id"], "state": state,
                        "connected": bool(c["connected"]), "ordering": c["ordering"],
                        "covered_through": c["covered_through"], "covered_at": c["covered_at"],
                        "holes": holes, "missing_count": missing_count})
        overall = "unknown" if not out or any(o["state"] == "unknown" for o in out) else "gaps" if any(o["state"] == "gaps" for o in out) else "complete"
        return {"state": overall, "conversations": out}

    # ---- reading direction -----------------------------------------------------------------

    def _holes(self, conv_pk, first, upto, limit=20):
        """Missing sequence numbers in [first, upto] as at most `limit` [lo, hi] ranges, plus the
        exact count — from the (conv_pk, source_seq) index, without materializing the range."""
        if upto < first:
            return [], 0
        have = self.db.execute("SELECT count(*) FROM message WHERE conv_pk = ? AND source_seq BETWEEN ? AND ?",
                               (conv_pk, first, upto)).fetchone()[0]
        missing = (upto - first + 1) - have
        if not missing:
            return [], 0
        rows = self.db.execute("""
            SELECT prev + 1 AS lo, seq - 1 AS hi FROM (
              SELECT source_seq AS seq, LAG(source_seq, 1, :first - 1) OVER (ORDER BY source_seq) AS prev
              FROM (SELECT source_seq FROM message WHERE conv_pk = :c AND source_seq BETWEEN :first AND :upto
                    UNION ALL SELECT :upto + 1))
            WHERE seq - prev > 1 ORDER BY lo LIMIT :n""", {"c": conv_pk, "first": first, "upto": upto, "n": limit}).fetchall()
        return [[r["lo"], r["hi"]] for r in rows], missing

    def messages(self, work_id):
        """The work's user direction, in source order within each conversation (unordered
        messages after, by receipt), each marked with whether later direction superseded it."""
        rows = self.db.execute("""
            SELECT m.*, c.source_id, c.conversation_id, mw.how, mw.decided_by,
                   (SELECT group_concat(s.message_id) FROM supersession s WHERE s.supersedes = m.message_id AND s.work_id = mw.work_id) AS superseded_by,
                   (SELECT group_concat(s.supersedes) FROM supersession s WHERE s.message_id = m.message_id AND s.work_id = mw.work_id) AS supersedes
            FROM message m JOIN message_work mw USING (message_id) JOIN conversation c USING (conv_pk)
            WHERE mw.work_id = ? AND m.author = 'user'
            ORDER BY c.source_id, c.conversation_id, m.source_seq IS NULL, m.source_seq, m.received_at, m.message_id""", (work_id,)).fetchall()
        rev = {r["message_id"]: r["revision"] for r in self.db.execute(
            "SELECT message_id, revision FROM work_revision WHERE work_id = ? AND message_id IS NOT NULL", (work_id,))}
        return [{"message_id": r["message_id"], "source": r["source_id"], "conversation": r["conversation_id"],
                 "source_message_id": r["source_message_id"], "source_seq": r["source_seq"], "source_time": r["source_time"],
                 "received_at": r["received_at"], "text": r["text"], "how": r["how"], "decided_by": r["decided_by"],
                 "revision": rev.get(r["message_id"]),
                 "supersedes": (r["supersedes"] or "").split(",") if r["supersedes"] else [],
                 "superseded_by": (r["superseded_by"] or "").split(",") if r["superseded_by"] else []} for r in rows]

    def latest(self, work_id):
        """The latest literal user message, by source order — never by arrival. With direction
        from more than one conversation, or unordered messages, there is no invented total
        order: `latest` is None and `heads` lists each conversation's newest message."""
        groups = {}
        for m in self.messages(work_id):
            groups.setdefault((m["source"], m["conversation"]), []).append(m)
        heads, unordered = [], False
        for ms in groups.values():
            ordered = [m for m in ms if m["source_seq"] is not None]
            unordered = unordered or (len(ms) > 1 and len(ordered) < len(ms))
            heads.append(max(ordered, key=lambda m: m["source_seq"]) if ordered else ms[-1])
        if len(heads) == 1 and not unordered:
            return {"latest": heads[0], "order": "source", "heads": heads}
        return {"latest": None, "order": "none" if not heads else "ambiguous", "heads": heads}

    def context(self, work_id):
        """What a worker must receive for this work: the revision, the accumulated direction
        (everything not superseded, in order), the latest literal message, and coverage."""
        with self.snapshot():
            return self._context(work_id)

    def _context(self, work_id):
        w = self.work(work_id)
        if w is None:
            raise JournalError(f"no work {work_id}")
        msgs = self.messages(work_id)
        return {"work": {k: w[k] for k in ("work_id", "todo_id", "repo", "project", "branch", "title", "retired_at")},
                "revision": w["revision"],
                "direction": [m for m in msgs if not m["superseded_by"]],
                "superseded": [m for m in msgs if m["superseded_by"]],
                **{k: v for k, v in self.latest(work_id).items()},
                "unassigned": self.unassigned_for(work_id),
                "coverage": self.coverage(work_id)}

    def unassigned_for(self, work_id):
        """User messages captured unassigned in conversations that have ever carried this work —
        visible as needing a decision, never folded into its direction."""
        return [dict(r) for r in self.db.execute("""
            SELECT m.message_id, m.source_seq, m.received_at, m.text, c.source_id AS source, c.conversation_id AS conversation
            FROM message m JOIN conversation c USING (conv_pk)
            WHERE m.author = 'user' AND NOT EXISTS (SELECT 1 FROM message_work mw WHERE mw.message_id = m.message_id)
              AND m.conv_pk IN (SELECT conv_pk FROM binding_work WHERE work_id = ?)
            ORDER BY m.source_seq IS NULL, m.source_seq, m.received_at""", (work_id,))]

    def revisions(self, work_id):
        return [dict(r) for r in self.db.execute("SELECT * FROM work_revision WHERE work_id = ? ORDER BY revision", (work_id,))]

    # ---- outbox ----------------------------------------------------------------------------

    def lease(self, owner, *, ttl=60.0, limit=10):
        """Claims due outbox rows for one dispatcher: pending ones, and leased ones whose
        dispatcher died (lease expired). Each claim counts as an attempt."""
        now = self.clock()
        with self.tx() as db:
            rows = db.execute("""SELECT outbox_id FROM outbox WHERE (state = 'pending' AND not_before <= :now)
                                 OR (state = 'leased' AND lease_until <= :now) ORDER BY outbox_id LIMIT :n""",
                              {"now": now, "n": limit}).fetchall()
            ids = [r["outbox_id"] for r in rows]
            for i in ids:
                db.execute("""UPDATE outbox SET state = 'leased', lease_owner = ?, lease_token = ?, lease_until = ?,
                              attempts = attempts + 1 WHERE outbox_id = ?""", (owner, uuid.uuid4().hex, now + ttl, i))
            return [dict(r) for r in db.execute(
                f"SELECT o.*, m.text, m.source_message_id FROM outbox o JOIN message m USING (message_id) WHERE outbox_id IN ({','.join('?' * len(ids))}) ORDER BY outbox_id", ids)] if ids else []

    def settle(self, outbox_id, lease_token, outcome, *, error=None, retry_in=30.0, max_attempts=8):
        """A dispatcher reports one leased row by the token `lease` issued it: delivered,
        uncertain (handed off, no acknowledgement — never silently retried as if unsent), or
        failed (retried later, abandoned after max_attempts). A report from an expired lease is
        refused even when the same dispatcher reclaimed the row since: the token, not the
        dispatcher's name, identifies the lease."""
        if outcome not in ("delivered", "uncertain", "failed"):
            raise JournalError(f"outcome {outcome!r}")
        with self.tx() as db:
            row = db.execute("SELECT * FROM outbox WHERE outbox_id = ?", (outbox_id,)).fetchone()
            if row is None:
                raise JournalError(f"no outbox row {outbox_id}")
            if row["state"] != "leased" or not lease_token or row["lease_token"] != lease_token:
                raise Conflict(f"outbox row {outbox_id} is not held by that lease")
            if outcome == "failed":
                state = "abandoned" if row["attempts"] >= max_attempts else "pending"
                db.execute("UPDATE outbox SET state = ?, lease_owner = NULL, lease_token = NULL, lease_until = NULL, not_before = ?, last_error = ?, settled_at = ? WHERE outbox_id = ?",
                           (state, self.clock() + retry_in, error, self.now() if state == "abandoned" else None, outbox_id))
            else:
                db.execute("UPDATE outbox SET state = ?, lease_owner = NULL, lease_token = NULL, lease_until = NULL, last_error = ?, settled_at = ? WHERE outbox_id = ?",
                           (outcome, error, self.now(), outbox_id))

    def outbox(self, *, states=None):
        q = "SELECT * FROM outbox"
        args = ()
        if states:
            q += f" WHERE state IN ({','.join('?' * len(states))})"
            args = tuple(states)
        return [dict(r) for r in self.db.execute(q + " ORDER BY outbox_id", args)]


def _statements(script):
    """Splits the schema into statements, keeping trigger bodies whole."""
    out, buf = [], ""
    for line in script.splitlines(keepends=True):
        buf += line
        if sqlite3.complete_statement(buf):
            if buf.strip():
                out.append(buf.strip())
            buf = ""
    return out


def dumps(obj):
    return json.dumps(obj, indent=1, sort_keys=True)
