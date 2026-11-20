"""A leased, single-file accepted-save journal for disposable editor experiments."""
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import stat


class Refused(Exception):
    pass


def identity(path):
    value = os.lstat(path)
    return value.st_dev, value.st_ino


@contextmanager
def transaction(db):
    db.execute("BEGIN IMMEDIATE")
    try:
        yield
        db.execute("COMMIT")
    except BaseException:
        db.execute("ROLLBACK")
        raise


class SaveJournal:
    @staticmethod
    def create(root, content, snapshot, generation):
        root = Path(root)
        root.mkdir(mode=0o700)
        (root / "files").mkdir()
        (root / "files/main.probe").write_bytes(content.encode("utf-8"))
        (root / "canopy-save-lab").write_text("1\n")
        (root / "bridge.lock").touch(mode=0o600)
        (root / "editor.lock").touch(mode=0o600)
        db = sqlite3.connect(root / "save.sqlite", isolation_level=None)
        try:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("PRAGMA synchronous=FULL")
            db.executescript("""
                BEGIN IMMEDIATE;
                PRAGMA user_version=1;
                CREATE TABLE state(id INTEGER PRIMARY KEY CHECK(id=1), generation TEXT, uri TEXT, snapshot TEXT,
                    revision INTEGER, uncertain INTEGER, root_dev INTEGER, root_ino INTEGER,
                    projection_dev INTEGER, projection_ino INTEGER);
                CREATE TABLE versions(revision INTEGER PRIMARY KEY, operation TEXT UNIQUE, payload TEXT, receipt TEXT,
                    content BLOB, mode TEXT);
            """)
            db.execute("INSERT INTO state VALUES(1,?,?,?,0,0,?,?,?,?)", (generation,
                (root.resolve() / "files/main.probe").as_uri(), snapshot, *identity(root), *identity(root / "files")))
            db.execute("INSERT INTO versions VALUES(0,NULL,NULL,NULL,?,'100644')", (content.encode("utf-8"),))
            db.execute("COMMIT")
        finally:
            db.close()
        for path in (root / "files/main.probe", root / "canopy-save-lab", root / "bridge.lock", root / "editor.lock"):
            with path.open("rb") as stream:
                os.fsync(stream.fileno())
        for path in (root / "files", root):
            fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)

    def __init__(self, root, generation, fault=lambda _: None, projection_fd=None):
        self.root = Path(root).absolute()
        if self.root.is_symlink() or (self.root / "canopy-save-lab").read_text() != "1\n":
            raise Refused("this is not a disposable save-bridge fixture")
        self.generation, self.fault = generation, fault
        self.file = self.root / "files/main.probe"
        self.identities = {path: identity(path) for path in (self.root, self.root / "files", self.root / "save.sqlite", self.root / "bridge.lock", self.root / "editor.lock")}
        self.projection_fd = os.dup(projection_fd) if projection_fd is not None else os.open(self.root / "editor.lock", os.O_RDWR | os.O_NOFOLLOW)
        try:
            value = os.fstat(self.projection_fd)
            if (value.st_dev, value.st_ino) != self.identities[self.root / "editor.lock"]:
                raise Refused("the editor lease belongs to another projection")
            fcntl.flock(self.projection_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BaseException:
            os.close(self.projection_fd)
            raise Refused("another editor owns the projection")
        self.fd = None
        try:
            self.fd = os.open(self.root / "bridge.lock", os.O_RDWR | os.O_NOFOLLOW)
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BaseException:
            if self.fd is not None:
                os.close(self.fd)
            os.close(self.projection_fd)
            raise Refused("another editor owns the save journal")
        try:
            self.db = sqlite3.connect((self.root / "save.sqlite").as_uri() + "?mode=rw", uri=True, isolation_level=None)
            self.db.row_factory = sqlite3.Row
            self.db.execute("PRAGMA synchronous=FULL")
            if self.db.execute("PRAGMA user_version").fetchone()[0] != 1:
                raise Refused("unknown save journal version")
            state = self.state
            if ((state["root_dev"], state["root_ino"]) != self.identities[self.root]
                    or (state["projection_dev"], state["projection_ino"]) != self.identities[self.root / "files"]
                    or state["uri"] != self.file.resolve().as_uri()):
                raise Refused("the journal belongs to another projection")
            with transaction(self.db):
                self.db.execute("UPDATE state SET generation=? WHERE id=1", (generation,))
        except BaseException:
            if hasattr(self, "db"):
                self.db.close()
            os.close(self.fd)
            os.close(self.projection_fd)
            raise

    def owned(self):
        if any(identity(path) != expected for path, expected in self.identities.items()):
            raise Refused("the save journal or projection was replaced")
        if (os.fstat(self.fd).st_dev, os.fstat(self.fd).st_ino) != self.identities[self.root / "bridge.lock"]:
            raise Refused("the journal lease changed")
        if (os.fstat(self.projection_fd).st_dev, os.fstat(self.projection_fd).st_ino) != self.identities[self.root / "editor.lock"]:
            raise Refused("the editor projection lease changed")

    @property
    def state(self):
        return self.db.execute("SELECT * FROM state WHERE id=1").fetchone()

    def snapshot(self, revision=None):
        revision = self.state["revision"] if revision is None else revision
        row = self.db.execute("SELECT content,mode FROM versions WHERE revision=?", (revision,)).fetchone()
        if row is None:
            raise Refused("unknown accepted revision")
        return bytes(row["content"]), row["mode"]

    def ready(self):
        self.owned()
        content, mode = self.snapshot()
        metadata = os.lstat(self.file)
        actual_mode = "100755" if metadata.st_mode & 0o111 else "100644"
        if not stat.S_ISREG(metadata.st_mode) or self.file.read_bytes() != content or actual_mode != mode or self.state["uncertain"]:
            self.db.execute("UPDATE state SET uncertain=1 WHERE id=1")
            raise Refused("projection differs from the accepted draft; explicit reconciliation is required")
        return {"protocol": 1, "generation": self.generation, "uri": self.state["uri"], "revision": self.state["revision"]}

    def accept(self, payload):
        self.owned()
        required = {"generation", "operation", "expectedRevision", "documentVersion", "uri", "text", "mode"}
        if (not isinstance(payload, dict) or set(payload) != required or not isinstance(payload["operation"], str) or not payload["operation"]
                or type(payload["expectedRevision"]) is not int or not 0 <= payload["expectedRevision"] < (1 << 63) - 1
                or type(payload["documentVersion"]) is not int or payload["documentVersion"] < 0
                or not isinstance(payload["text"], str) or payload["mode"] not in ("100644", "100755")):
            raise Refused("invalid save payload")
        encoded = json.dumps(payload, sort_keys=True, ensure_ascii=True, separators=(",", ":"))
        with transaction(self.db):
            self.owned()
            state = self.state
            if payload["generation"] != state["generation"] or payload["generation"] != self.generation or payload["uri"] != state["uri"]:
                raise Refused("this save belongs to another owner or document")
            if state["uncertain"]:
                raise Refused("an opaque writer requires explicit reconciliation")
            previous = self.db.execute("SELECT payload,receipt FROM versions WHERE operation=?", (payload["operation"],)).fetchone()
            if previous:
                if previous["payload"] != encoded:
                    raise Refused("the save operation changed")
                return json.loads(previous["receipt"])
            if state["revision"] != payload["expectedRevision"]:
                raise Refused("the writer's observed revision is stale")
            revision = state["revision"] + 1
            receipt = {"generation": self.generation, "operation": payload["operation"], "revision": revision,
                       "acceptedText": payload["text"], "mode": payload["mode"]}
            self.db.execute("INSERT INTO versions VALUES(?,?,?,?,?,?)", (revision, payload["operation"], encoded,
                json.dumps(receipt, sort_keys=True), payload["text"].encode("utf-8"), payload["mode"]))
            self.db.execute("UPDATE state SET revision=? WHERE id=1", (revision,))
            self.fault("before-commit")
        self.fault("after-commit")
        return receipt

    def close(self):
        self.db.close()
        os.close(self.fd)
        os.close(self.projection_fd)
