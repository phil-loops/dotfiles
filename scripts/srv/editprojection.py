"""Recoverable synchronization of a frozen edit into an attached Git worktree."""
import os
from pathlib import Path
import shutil
import stat
import uuid

from . import ghreview


def _identity(path):
    value = os.lstat(path)
    return [value.st_dev, value.st_ino]


def _stamp(path):
    value = os.stat(path)
    return [value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns]


def _gitdir(checkout):
    marker = checkout / ".git"
    if marker.is_dir():
        return marker.resolve()
    target = marker.read_text().strip()
    if not target.startswith("gitdir: "):
        raise ghreview.Refused("the attached checkout's Git directory changed; its files are preserved")
    return (checkout / target.removeprefix("gitdir: ")).resolve()


def _copy(source, destination):
    shutil.copy2(source, destination)
    with open(destination, "rb") as stream:
        os.fsync(stream.fileno())


class Projection:
    def __init__(self, root, session, checkout, *, git, save):
        self.root, self.session = root, session
        self.checkout = Path(checkout)
        self.git, self.save = git, save
        self.locks = []
        self.installed = False

    def text(self, *args, **kw):
        return self.git(*args, cwd=self.checkout, **kw).decode().strip()

    def persist(self, phase):
        self.session["projection"]["phase"] = phase
        self.session["state"] = "landing"
        self.save(self.root / "session.json", self.session)

    def validate(self):
        saved = self.session["projection"]
        gitdir = _gitdir(self.checkout)
        marker = gitdir / "commondir"
        common = (gitdir / marker.read_text().strip()).resolve() if marker.exists() else gitdir
        if (str(self.checkout) != saved["checkout"] or _identity(self.checkout) != saved["checkoutIdentity"]
                or _identity(saved["gitdir"]) != saved["gitdirIdentity"]
                or str(gitdir) != saved["gitdir"] or str(common) != self.session["repo"]):
            raise ghreview.Refused("the attached checkout was replaced; the frozen save and recovery journal are preserved")

    def release_stale(self):
        self.validate()
        for record in self.session["projection"].get("locks", []):
            path = Path(record["path"])
            if not os.path.lexists(path):
                continue
            if _identity(path) != record["identity"]:
                raise ghreview.Refused("another Git operation owns the checkout lock; the recovery journal is preserved")
            with path.open("rb") as stream:
                if stream.read(33) != record["token"].encode():
                    raise ghreview.Refused("the interrupted checkout lock changed; it is preserved for inspection")
            path.unlink()

    def head(self):
        if (Path(self.session["projection"]["gitdir"]) / "HEAD").read_text().strip() != f"ref: refs/heads/{self.session['branch']}":
            raise ghreview.Refused("the attached checkout switched branches; the frozen save and recovery journal are preserved")

    def __enter__(self):
        saved = self.session.get("projection")
        if saved:
            self.release_stale()
        else:
            gitdir = str(_gitdir(self.checkout))
            self.session["projection"] = {"checkout": str(self.checkout), "checkoutIdentity": _identity(self.checkout),
                "gitdir": gitdir, "gitdirIdentity": _identity(gitdir), "locks": []}
        saved = self.session["projection"]
        self.validate()
        self.head()
        try:
            saved["locks"] = []
            for name in ("index.lock",):
                path = Path(saved["gitdir"]) / name
                try:
                    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                except FileExistsError:
                    raise ghreview.Refused("another Git operation owns the attached checkout; retry after it finishes")
                record = {"path": str(path), "identity": _identity(path), "token": uuid.uuid4().hex}
                self.locks.append((path, fd, record))
                os.write(fd, record["token"].encode())
                os.fsync(fd)
                saved["locks"].append(record)
                self.persist(saved.get("phase", "locked"))
            self.head()
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, *_):
        for path, fd, record in reversed(self.locks):
            try:
                if os.path.lexists(path) and _identity(path) == record["identity"]:
                    path.unlink()
            finally:
                os.close(fd)
        self.locks.clear()

    def tree(self, index):
        return self.text("write-tree", env={**os.environ, "GIT_INDEX_FILE": str(index)})

    def matches_after(self, paths):
        tree = self.session["projection"]["afterTree"]
        entries = {}
        try:
            raw = self.git("ls-tree", "-r", "-z", tree, "--", *paths, cwd=self.checkout,
                           env={**os.environ, "GIT_LITERAL_PATHSPECS": "1"})
            for entry in raw.split(b"\0"):
                if entry:
                    fields, path = entry.split(b"\t", 1)
                    mode, _, blob = fields.decode().split()
                    entries[os.fsdecode(path)] = mode, blob
            for name in paths:
                path = self.checkout / name
                expected = entries.get(name)
                if expected is None:
                    if os.path.lexists(path) and not (path.is_dir() and any(p.startswith(name + "/") for p in entries)):
                        return False
                    continue
                mode, blob = expected
                actual = os.lstat(path)
                if mode == "120000":
                    if not stat.S_ISLNK(actual.st_mode):
                        return False
                    content = self.git("hash-object", "--stdin", cwd=self.checkout, input=os.fsencode(os.readlink(path)))
                elif mode in ("100644", "100755"):
                    if not stat.S_ISREG(actual.st_mode) or bool(actual.st_mode & 0o111) != (mode == "100755"):
                        return False
                    content = self.git("hash-object", f"--path={name}", "--", name, cwd=self.checkout)
                else:
                    return False
                if content.decode().strip() != blob:
                    return False
        except (ghreview.Refused, OSError):
            return False
        return True

    def apply(self, *, committed=False):
        saved = self.session["projection"]
        index = Path(saved["gitdir"]) / "index"
        before = self.root / "attached-index-before"
        after = self.root / "attached-index-after"
        working = self.root / "attached-index-working"
        _copy(index, working)
        current = self.tree(working)
        tip, new = self.session["expectedTip"], self.session["receipt"]["sha"]
        planned = "beforeTree" in saved
        if not planned:
            _copy(index, before)
            self.git("read-tree", "-m", tip, new, cwd=self.checkout,
                     env={**os.environ, "GIT_INDEX_FILE": str(working)})
            saved.update(beforeTree=current, afterTree=self.tree(working))
            _copy(working, after)
            saved["paths"] = [os.fsdecode(path) for path in self.git("diff-tree", "--no-commit-id", "--name-only", "-r", "-z",
                saved["beforeTree"], saved["afterTree"], cwd=self.checkout).split(b"\0") if path]
            self.persist("planned")
        elif current == saved["afterTree"]:
            self.persist("index-applied")
            self.installed = True
            return
        elif current != saved["beforeTree"]:
            raise ghreview.Refused("the attached index changed after the interrupted save; its files and recovery journal are preserved")
        if planned and (self.tree(before) != saved["beforeTree"] or self.tree(after) != saved["afterTree"]):
            raise ghreview.Refused("the saved index snapshots changed; the checkout and frozen save are preserved")
        self.head()
        if committed or saved["phase"] in ("files-applied", "index-applied") or (planned and self.matches_after(saved["paths"])):
            _copy(after, working)
        else:
            _copy(before, working)
            self.git("read-tree", "-m", "-u", tip, new, cwd=self.checkout,
                     env={**os.environ, "GIT_INDEX_FILE": str(working)})
        if self.tree(working) != saved["afterTree"]:
            raise ghreview.Refused("the attached index did not reach the planned revision; the recovery journal is preserved")
        self.working_stamp = _stamp(working)
        self.persist("files-applied")
        self.head()

    def install(self):
        if self.installed:
            return
        saved = self.session["projection"]
        index = Path(saved["gitdir"]) / "index"
        working = self.root / "attached-index-working"
        if _stamp(working) != self.working_stamp:
            raise ghreview.Refused("the pending index changed; the frozen save and recovery journal are preserved")
        path, fd, _ = self.locks[0]
        os.lseek(fd, 0, os.SEEK_SET)
        os.ftruncate(fd, 0)
        with working.open("rb") as source, os.fdopen(os.dup(fd), "wb") as target:
            shutil.copyfileobj(source, target)
            target.flush()
            os.fchmod(target.fileno(), stat.S_IMODE(index.stat().st_mode))
            stamp = working.stat()
            os.utime(target.fileno(), ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
            os.fsync(target.fileno())
        os.replace(path, index)
        directory = os.open(index.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        self.persist("index-applied")
