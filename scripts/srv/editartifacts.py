"""Retire unchanged generated indexes after a workspace's save is committed."""
import os
import stat
import uuid

from . import ghreview

FILES = frozenset({"warm-index", "snapshot-index", "attached-index-before", "attached-index-after", "attached-index-working"})
PREFIX = ".retired-index-"


def _stamp(value):
    return [value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns] if stat.S_ISREG(value.st_mode) else None


def remember(root, session, name):
    if name not in FILES:
        raise ValueError("not a generated editor index")
    value = _stamp(os.lstat(root / name))
    if value is not None:
        session.setdefault("artifacts", {})[name] = value


def matches(root, session, name):
    try:
        value = _stamp(os.lstat(root / name))
        return name in FILES and value is not None and session.get("artifacts", {}).get(name) == value
    except OSError:
        return False


def collect(root, session, *, save):
    if session.get("state") != "committed" or not session.get("receipt") or "workspaceIdentity" not in session:
        return
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        identity = os.fstat(fd)
        if [identity.st_dev, identity.st_ino] != session["workspaceIdentity"]:
            raise ghreview.Refused("the workspace directory was replaced; its generated files are preserved")
        artifacts = session.setdefault("artifacts", {})
        retiring = session.setdefault("retiringArtifacts", {})
        if not isinstance(artifacts, dict) or not isinstance(retiring, dict):
            raise ghreview.Refused("the artifact journal changed; generated files are preserved")

        def stamp(name):
            try:
                return _stamp(os.stat(name, dir_fd=fd, follow_symlinks=False))
            except FileNotFoundError:
                return None

        def exists(name):
            try:
                os.stat(name, dir_fd=fd, follow_symlinks=False)
                return True
            except FileNotFoundError:
                return False

        planned = False
        changed = False
        for name, proof in list(artifacts.items()):
            if name in FILES and name not in retiring and not exists(name):
                del artifacts[name]
                changed = True
                continue
            if name in FILES and name not in retiring and proof is not None and stamp(name) == proof:
                retiring[name] = PREFIX + str(uuid.uuid4())
                planned = True
        if planned:
            save(root / "session.json", session, directory_fd=fd)
        for name, target in list(retiring.items()):
            if name not in FILES or not isinstance(target, str) or not target.startswith(PREFIX):
                continue
            try:
                uuid.UUID(target.removeprefix(PREFIX))
            except ValueError:
                continue
            proof = artifacts.get(name)
            if not isinstance(proof, list) or len(proof) != 5:
                continue
            if not exists(target):
                if stamp(name) == proof:
                    os.rename(name, target, src_dir_fd=fd, dst_dir_fd=fd)
                else:
                    del retiring[name]
                    if not exists(name):
                        artifacts.pop(name, None)
                    changed = True
                    continue
            value = stamp(target)
            if value is None or value[:4] != proof[:4]:
                try:
                    os.link(target, name, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
                    os.unlink(target, dir_fd=fd)
                except OSError:
                    session.setdefault("preservedArtifacts", {})[target] = name
                del retiring[name]
                changed = True
                continue
            os.unlink(target, dir_fd=fd)
            artifacts.pop(name, None)
            del retiring[name]
            changed = True
        if changed:
            save(root / "session.json", session, directory_fd=fd)
    finally:
        os.close(fd)
