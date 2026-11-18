"""Kernel leases and process identities for private editor attachments."""
from contextlib import contextmanager
import ctypes
import errno
import fcntl
from functools import lru_cache
import json
import os
from pathlib import Path
import sys
import uuid

from . import editprojection, ghreview


def write_record(path, data, *, directory_fd=None):
    temporary = path.with_suffix(".tmp").name
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY) if directory_fd is None else directory_fd
    try:
        out_fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o666, dir_fd=fd)
        with os.fdopen(out_fd, "w") as out:
            json.dump(data, out)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temporary, path.name, src_dir_fd=fd, dst_dir_fd=fd)
        os.fsync(fd)
    finally:
        if directory_fd is None:
            os.close(fd)


@lru_cache(maxsize=1)
def _darwin_api():
    class BSDInfo(ctypes.Structure):
        _fields_ = [(name, ctypes.c_uint32) for name in ("flags", "status", "xstatus", "pid", "ppid", "uid", "gid",
                    "ruid", "rgid", "svuid", "svgid", "reserved")] + [("command", ctypes.c_char * 16), ("name", ctypes.c_char * 32)] \
            + [(name, ctypes.c_uint32) for name in ("nfiles", "pgid", "pjobc", "tty", "tty_pgid")] \
            + [("nice", ctypes.c_int32), ("started_sec", ctypes.c_uint64), ("started_usec", ctypes.c_uint64)]
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    lib.proc_pidinfo.restype = ctypes.c_int
    return lib, BSDInfo


def process_identity(pid):
    """Return a kernel birth identity, or None only when the process is gone."""
    if type(pid) is not int or pid <= 0:
        raise ghreview.Refused("the editor's process identity is unavailable; its workspace is preserved")
    if sys.platform == "darwin":
        lib, BSDInfo = _darwin_api()
        value = BSDInfo()
        ctypes.set_errno(0)
        size = lib.proc_pidinfo(pid, 3, 0, ctypes.byref(value), ctypes.sizeof(value))
        if size == ctypes.sizeof(value) and value.pid == pid:
            return ["darwin", pid, value.started_sec, value.started_usec]
        if ctypes.get_errno() == errno.ESRCH:
            return None
    elif sys.platform.startswith("linux"):
        try:
            fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
            boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
            return ["linux", pid, boot, fields[19]]
        except FileNotFoundError:
            return None
        except (OSError, IndexError):
            pass
    raise ghreview.Refused("couldn't prove the editor has exited; its workspace is preserved")


def _identity(path):
    value = os.lstat(path)
    return [value.st_dev, value.st_ino]


@contextmanager
def available(root, session):
    if session.get("leaseProtocol") != 1:
        yield None
        return
    attachment = session.get("attachment") or {}
    path = root / "editor.lock"
    try:
        fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    except OSError:
        raise ghreview.Refused("the editor lease file changed; its workspace is preserved")
    try:
        value = os.fstat(fd)
        if attachment.get("identity") != [value.st_dev, value.st_ino] or _identity(path) != attachment["identity"]:
            raise ghreview.Refused("the editor lease file was replaced; its workspace is preserved")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ghreview.Refused("that workspace still has a live editor")
        process = attachment.get("process")
        if process is not None:
            if not isinstance(process, list) or len(process) != 4:
                raise ghreview.Refused("the editor's process identity changed; its workspace is preserved")
            if process_identity(process[1]) == process:
                raise ghreview.Refused("that workspace still has a live editor")
        yield fd
    except OSError:
        raise ghreview.Refused("couldn't verify the editor lease; its workspace is preserved")
    finally:
        os.close(fd)


def issue(root, session, *, save):
    if session.get("leaseProtocol") != 1:
        return None
    if "attachment" not in session:
        path = root / "editor.lock"
        try:
            fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except FileExistsError:
            raise ghreview.Refused("an unrecorded editor lease exists; its workspace is preserved")
        try:
            os.fsync(fd)
            value = os.fstat(fd)
            session["attachment"] = {"identity": [value.st_dev, value.st_ino]}
            save(root / "session.json", session)
        finally:
            os.close(fd)
    with available(root, session):
        session["attachment"].update(token=str(uuid.uuid4()), process=None)
        save(root / "session.json", session)
    return {"script": str(Path(__file__).resolve().parents[1] / "canopy-editor"),
            "record": str(root / "session.json"), "token": session["attachment"]["token"]}


def resumable(root, session):
    if session.get("leaseProtocol") != 1 or session.get("state") != "editing" or session.get("operation"):
        return False
    try:
        with available(root, session):
            return True
    except (ghreview.Refused, OSError):
        return False


def launch(record, token, position):
    """Attach exactly once to the selected workspace and exec Helix under its lease."""
    record = Path(record).resolve()
    root = record.parent
    with (root / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        session = json.loads(record.read_text())
        if (not isinstance(session, dict) or record.name != "session.json" or session.get("session") != root.name or session.get("workspaceVersion") != 1
                or session.get("kind") != "editor" or session.get("state") != "editing" or session.get("operation")
                or session.get("leaseProtocol") != 1 or session.get("attachment", {}).get("token") != token):
            raise ghreview.Refused("that editor attachment is no longer current; its workspace is preserved")
        checkout = Path(session["checkout"])
        gitdir = editprojection._gitdir(checkout)
        common = (gitdir / (gitdir / "commondir").read_text().strip()).resolve()
        if (checkout.resolve() != Path.cwd().resolve() or _identity(checkout) != session["checkoutIdentity"]
                or _identity(session["repo"]) != session["identity"] or str(gitdir) != session["gitdir"]
                or str(common) != session["repo"]
                or _identity(gitdir) != session["gitdirIdentity"]
                or (gitdir / "HEAD").read_text().strip() != session["baseSha"]):
            raise ghreview.Refused("the editor workspace changed; its files are preserved")
        path, line, col = position.rsplit(":", 2)
        if not path or any(part in ("", ".", "..") for part in path.split("/")) or int(line) <= 0 or int(col) <= 0:
            raise ghreview.Refused("the editor position is outside its workspace")
        with available(root, session) as fd:
            session["attachment"]["process"] = process_identity(os.getpid())
            write_record(record, session)
            os.set_inheritable(fd, True)
            fcntl.flock(lock, fcntl.LOCK_UN)
            os.execvpe("hx", ["hx", "--", position], os.environ)
