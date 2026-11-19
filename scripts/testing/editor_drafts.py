"""Isolated draft-storage experiments; never imported by the production editor."""
import hashlib
from contextlib import contextmanager
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import threading
import uuid


class Refused(Exception):
    pass


def path_parts(path):
    if not isinstance(path, str) or "\0" in path or any(part in ("", ".", "..", ".git") for part in path.split("/")):
        raise Refused("invalid draft path")
    return path.encode("utf-8").split(b"/")


@contextmanager
def transaction(db):
    db.execute("BEGIN IMMEDIATE")
    try:
        yield
    except BaseException:
        db.execute("ROLLBACK")
        raise
    else:
        db.execute("COMMIT")


class Objects:
    def __init__(self, repo):
        self.repo = Path(repo).resolve()
        if (self.repo / "canopy-draft-lab").read_text() != "disposable\n":
            raise Refused("the experiment requires a marked disposable bare repository")
        value = self.repo.stat()
        self.identity = value.st_dev, value.st_ino
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="Draft lab",
                        GIT_AUTHOR_EMAIL="draft@example.invalid", GIT_COMMITTER_NAME="Draft lab", GIT_COMMITTER_EMAIL="draft@example.invalid")
        self.calls = []
        self.reads = []
        self.cache = {}
        self.process = None
        self.lock = threading.Lock()

    def argv(self, *args):
        return ["git", "--git-dir", str(self.repo), "-c", "core.fsync=all", "-c", "core.fsyncMethod=fsync",
                "-c", "commit.gpgsign=false", "-c", f"core.hooksPath={self.repo / 'no-hooks'}", *args]

    def bound(self):
        try:
            value = self.repo.lstat()
            if self.identity == (value.st_dev, value.st_ino):
                return
        except OSError:
            pass
        raise Refused("the experiment repository was replaced")

    def run(self, *args, data=None, index=None):
        self.bound()
        env = {**self.env, **({"GIT_INDEX_FILE": str(index)} if index else {})}
        result = subprocess.run(self.argv(*args), input=data, capture_output=True, env=env, timeout=120)
        self.calls.append(args)
        if result.returncode:
            raise Refused(result.stderr.decode(errors="replace").strip() or "Git refused the experiment")
        return result.stdout

    def text(self, *args, **kw):
        return self.run(*args, **kw).decode().strip()

    def object(self, oid):
        with self.lock:
            self.bound()
            if self.process is None:
                self.process = subprocess.Popen(self.argv("cat-file", "--batch"), env=self.env,
                                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            self.process.stdin.write(oid.encode() + b"\n")
            self.process.stdin.flush()
            header = self.process.stdout.readline().split()
            if len(header) != 3:
                raise Refused("the snapshot object is unavailable")
            size = int(header[2])
            content = self.process.stdout.read(size)
            if len(content) != size or self.process.stdout.read(1) != b"\n":
                raise Refused("the snapshot object was truncated")
            self.reads.append((header[1].decode(), size))
            return header[1].decode(), content

    def tree(self, oid):
        if oid is None:
            return {}
        if oid in self.cache:
            return self.cache[oid].copy()
        kind, content = self.object(oid)
        if kind != "tree":
            raise Refused("the snapshot path is not a tree")
        width = len(oid) // 2
        entries, offset = {}, 0
        while offset < len(content):
            space = content.index(b" ", offset)
            zero = content.index(b"\0", space)
            mode = content[offset:space].decode()
            entries[content[space + 1:zero]] = (mode, content[zero + 1:zero + 1 + width].hex())
            offset = zero + 1 + width
        self.cache[oid] = entries
        return entries.copy()

    def entry(self, tree, path):
        parts = path_parts(path)
        current = tree
        for index, part in enumerate(parts):
            entry = self.tree(current).get(part)
            if entry is None:
                raise FileNotFoundError(path)
            mode, current = entry
            if index < len(parts) - 1 and mode != "40000":
                raise Refused("a file blocks the draft path")
        return mode, current

    def read(self, tree, path):
        mode, current = self.entry(tree, path)
        if mode not in ("100644", "100755", "120000"):
            raise Refused("only file documents can be opened")
        kind, content = self.object(current)
        if kind != "blob":
            raise Refused("the document is not a blob")
        return mode, content

    def write(self, kind, content):
        return self.text("hash-object", "-w", "-t", kind, "--stdin", data=content)

    def rewrite(self, base, changes):
        grouped = {}
        for path, value in changes.items():
            parts = path_parts(path)
            node = grouped
            for part in parts[:-1]:
                if part in node and not isinstance(node[part], dict):
                    raise Refused("overlapping draft paths")
                node = node.setdefault(part, {})
            if parts[-1] in node:
                raise Refused("overlapping draft paths")
            node[parts[-1]] = value

        def build(oid, updates):
            entries = self.tree(oid)
            for name, value in updates.items():
                if isinstance(value, dict):
                    old = entries.get(name)
                    if old and old[0] != "40000":
                        raise Refused("a file blocks the draft directory")
                    child = build(old[1] if old else None, value)
                    if child:
                        entries[name] = ("40000", child)
                    else:
                        entries.pop(name, None)
                elif value is None:
                    if entries.get(name, (None,))[0] == "40000":
                        raise Refused("directory deletion needs an explicit file manifest")
                    entries.pop(name, None)
                else:
                    if entries.get(name, (None,))[0] == "40000":
                        raise Refused("directory replacement needs an explicit file manifest")
                    entries[name] = value
            if not entries:
                return None
            records = b"".join(mode.encode() + b" " + (b"tree" if mode == "40000" else b"commit" if mode == "160000" else b"blob")
                               + b" " + target.encode() + b"\t" + name + b"\0" for name, (mode, target) in entries.items())
            return self.text("mktree", "-z", data=records)
        return build(base, grouped) or self.text("mktree", data=b"")

    def close(self):
        if self.process:
            self.process.stdin.close()
            self.process.wait(timeout=5)
            self.process.stdout.close()
            self.process = None


class Draft:
    def __init__(self, root, objects, fault=lambda _: None):
        self.root, self.objects, self.fault = Path(root).resolve(), objects, fault
        self.db = sqlite3.connect((self.root / "draft.sqlite").as_uri() + "?mode=rw", uri=True, isolation_level=None, timeout=10)
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.row_factory = sqlite3.Row
        try:
            if self.db.execute("PRAGMA user_version").fetchone()[0] != 1:
                raise Refused("unknown draft journal version")
            self.meta = dict(self.db.execute("SELECT * FROM draft").fetchone())
            objects.bound()
            if self.meta["repo"] != str(objects.repo) or (self.meta["device"], self.meta["inode"]) != objects.identity:
                raise Refused("the draft belongs to another repository")
        except BaseException:
            self.db.close()
            raise

    @classmethod
    def create(cls, root, objects, backend, base):
        if backend not in ("workspace", "hybrid", "objects"):
            raise Refused("unknown draft backend")
        root = Path(root)
        root.mkdir()
        commit = objects.text("rev-parse", "--verify", base + "^{commit}")
        tree = objects.text("rev-parse", commit + "^{tree}")
        ref = "refs/heads/lab-" + uuid.uuid4().hex
        objects.run("update-ref", ref, commit, "0" * len(commit))
        db = sqlite3.connect(root / "draft.sqlite", isolation_level=None)
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA synchronous=FULL")
        db.executescript("""
            BEGIN IMMEDIATE;
            PRAGMA user_version=1;
            CREATE TABLE draft(repo TEXT, device INTEGER, inode INTEGER, backend TEXT, base TEXT, tree TEXT, ref TEXT, version INTEGER, opaque INTEGER);
            CREATE TABLE mutations(path TEXT PRIMARY KEY, mode TEXT, oid TEXT, content BLOB);
            CREATE TABLE operations(id TEXT PRIMARY KEY, fingerprint TEXT, version INTEGER);
            CREATE TABLE publication(id TEXT PRIMARY KEY, version INTEGER, tree TEXT, commit_oid TEXT, state TEXT);
        """)
        db.execute("INSERT INTO draft VALUES(?,?,?,?,?,?,?,0,0)", (str(objects.repo), *objects.identity, backend, commit, tree, ref))
        db.execute("COMMIT")
        db.close()
        instance = cls(root, objects)
        if backend != "objects":
            objects.run("-c", "checkout.workers=4", "worktree", "add", "--detach", str(root / "files"), commit)
        else:
            (root / "files").mkdir()
        directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        return instance

    @property
    def version(self):
        return self.db.execute("SELECT version FROM draft").fetchone()[0]

    def read(self, path):
        path_parts(path)
        row = self.db.execute("SELECT * FROM mutations WHERE path=?", (path,)).fetchone()
        if row:
            if row["mode"] is None:
                raise FileNotFoundError(path)
            return row["mode"], bytes(row["content"])
        return self.objects.read(self.meta["tree"], path)

    def project(self, path):
        mode, content = self.read(path)
        if mode == "120000":
            raise Refused("the thin editor projection does not follow symlinks")
        target = self.root / "files" / path
        base = self.root / "files"
        if base.is_symlink() or any(base.joinpath(*path.split("/")[:i]).is_symlink() for i in range(1, len(path.split("/")) + 1)):
            raise Refused("the editor projection contains an alias")
        if self.meta["backend"] == "objects" and not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
            target.chmod(0o755 if mode == "100755" else 0o644)
        return target

    def mutate(self, operation, version, changes):
        rows = []
        for path, value in sorted(changes.items()):
            path_parts(path)
            try:
                if self.objects.entry(self.meta["tree"], path)[0] == "40000":
                    raise Refused("a directory needs an explicit file manifest")
            except FileNotFoundError:
                pass
            if value is None:
                rows.append((path, None, None, None))
            else:
                mode, content = value
                if mode not in ("100644", "100755", "120000") or not isinstance(content, bytes):
                    raise Refused("invalid file mutation")
                algorithm = "sha256" if len(self.meta["base"]) == 64 else "sha1"
                oid = hashlib.new(algorithm, b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
                rows.append((path, mode, oid, content))
        digest = hashlib.sha256(json.dumps([version, [row[:3] for row in rows]], ensure_ascii=True).encode()).hexdigest()
        self.fault("content-hashed")
        with transaction(self.db):
            previous = self.db.execute("SELECT * FROM operations WHERE id=?", (operation,)).fetchone()
            if previous:
                if previous["fingerprint"] != digest:
                    raise Refused("the mutation operation changed")
                result = previous["version"]
            else:
                if self.db.execute("SELECT 1 FROM publication").fetchone() or self.version != version:
                    raise Refused("the draft revision changed or was frozen")
                self.db.executemany("INSERT OR REPLACE INTO mutations VALUES(?,?,?,?)", rows)
                self.db.execute("UPDATE draft SET version=version+1")
                self.db.execute("INSERT INTO operations VALUES(?,?,?)", (operation, digest, version + 1))
                self.fault("mutation-before-commit")
                result = version + 1
        self.fault("mutation-committed")
        return result

    def invalidate(self):
        self.db.execute("UPDATE draft SET opaque=1")

    def freeze(self, operation, version):
        with transaction(self.db):
            previous = self.db.execute("SELECT * FROM publication").fetchone()
            if previous:
                if previous["id"] != operation or previous["version"] != version:
                    raise Refused("another publication owns this draft")
                return dict(previous)
            if self.version != version or self.db.execute("SELECT opaque FROM draft").fetchone()[0]:
                raise Refused("the draft is stale or an opaque writer needs reconciliation")
            rows = list(self.db.execute("SELECT * FROM mutations ORDER BY path"))
            paths = {row["path"] for row in rows}
            if any("/".join(path.split("/")[:i]) in paths for path in paths for i in range(1, len(path.split("/")))):
                raise Refused("overlapping draft paths")
            changes = {}
            for row in rows:
                if row["mode"]:
                    oid = self.objects.write("blob", bytes(row["content"]))
                    if oid != row["oid"]:
                        raise Refused("the journaled content no longer matches its object identity")
                    changes[row["path"]] = (row["mode"], oid)
                else:
                    changes[row["path"]] = None
            if self.meta["backend"] == "workspace":
                index = self.root / "publication-index"
                index.unlink(missing_ok=True)
                self.objects.run("read-tree", self.meta["tree"], index=index)
                records = b"".join((value[0] + " " + value[1]).encode() + b"\t" + path.encode() + b"\0" if value
                                   else b"0 " + b"0" * len(self.meta["base"]) + b"\t" + path.encode() + b"\0"
                                   for path, value in changes.items())
                self.objects.run("update-index", "-z", "--index-info", data=records, index=index)
                tree = self.objects.text("write-tree", index=index)
            else:
                tree = self.objects.rewrite(self.meta["tree"], changes)
            commit = self.meta["base"] if tree == self.meta["tree"] else self.objects.text("commit-tree", tree, "-p", self.meta["base"],
                                                                                       data=b"edit a draft\n")
            self.objects.run("update-ref", "refs/canopy-lab/prepared/" + self.root.name, commit)
            self.db.execute("INSERT INTO publication VALUES(?,?,?,?,?)", (operation, version, tree, commit, "prepared"))
            self.fault("freeze-before-commit")
        self.fault("prepared")
        return dict(self.db.execute("SELECT * FROM publication").fetchone())

    def publish(self, operation, version):
        receipt = self.freeze(operation, version)
        current = self.objects.text("rev-parse", self.meta["ref"])
        if current == self.meta["base"]:
            try:
                self.objects.run("update-ref", self.meta["ref"], receipt["commit_oid"], self.meta["base"])
            except Refused:
                if self.objects.text("rev-parse", self.meta["ref"]) != receipt["commit_oid"]:
                    raise
            self.fault("ref-advanced")
        elif current != receipt["commit_oid"]:
            raise Refused("the publication ref moved; the frozen draft is preserved")
        self.db.execute("UPDATE publication SET state='committed'")
        self.fault("committed")
        return dict(self.db.execute("SELECT * FROM publication").fetchone())

    def close(self):
        self.db.close()


def fixture(repo, count=0, source=None, object_format="sha1"):
    repo = Path(repo).resolve()
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    if source:
        tip = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], env=environment).strip()
        subprocess.run(["git", "-c", f"core.hooksPath={repo / 'no-hooks'}", "clone", "--quiet", "--bare", "--shared", str(source), str(repo)],
                       env=environment, check=True, capture_output=True)
    else:
        tip = None
        subprocess.run(["git", "init", "--bare", "--quiet", "--object-format=" + object_format, str(repo)], env=environment, check=True, capture_output=True)
    (repo / "canopy-draft-lab").write_text("disposable\n")
    objects = Objects(repo)
    objects.run("config", "gc.auto", "0")
    payload = b"untouched source content\n"
    data = bytearray(b"blob\nmark :1\ndata " + str(len(payload)).encode() + b"\n" + payload + b"\n")
    data += b"commit refs/canopy-lab/fixture\ncommitter Draft lab <draft@example.invalid> 1700000000 +0000\ndata 5\nbase\n\n"
    if tip:
        data += b"from " + tip + b"\n"
    for index in range(count):
        data += f"M 100644 :1 payload/{index // 100:04d}/{index:06d}.txt\n".encode()
    for path, text in {"edit.txt": "before\n", "canopy-lab/main.ts": "import { value } from './helper';\nexport const answer = value;\n",
                       "canopy-lab/helper.ts": "export const value = 'snapshot import';\n",
                       "canopy-lab/tsconfig.json": '{"compilerOptions":{"strict":true,"target":"ES2022","module":"ESNext","moduleResolution":"bundler"},"files":["main.ts","helper.ts"]}\n'}.items():
        content = text.encode()
        data += f"M 100644 inline {path}\ndata {len(content)}\n".encode() + content + b"\n"
    objects.run("fast-import", "--quiet", data=data + b"\ndone\n")
    return objects
