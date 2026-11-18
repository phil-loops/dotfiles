"""Owned editor checkouts, frozen saves, and revision-qualified commit receipts."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import uuid

from . import ctx, ghreview, push, reviewdesk


def _epoch():
    from . import state
    return state.EPOCH


def _require_epoch(data):
    if data.get("epoch") != _epoch():
        raise ghreview.Refused("the server changed; the edit checkout and frozen save are preserved")


def _git(*args, cwd=None, env=None, input=None):
    source = env if env is not None else os.environ
    scrub = {"GIT_DIR", "GIT_WORK_TREE", "GIT_PREFIX"} | ({"GIT_INDEX_FILE"} if env is None else set())
    environment = {key: value for key, value in source.items() if key not in scrub}
    result = subprocess.run(["git", *args], cwd=cwd or ctx.repo_cwd(), env=environment,
                            input=input, capture_output=True)
    if result.returncode:
        raise ghreview.Refused(result.stderr.decode(errors="replace").strip()[-300:] or "Git failed")
    return result.stdout


def _text(*args, **kw):
    return _git(*args, **kw).decode().strip()


def _identity(path):
    stat = os.stat(path)
    return [stat.st_dev, stat.st_ino]


def _root(session):
    try:
        session = str(uuid.UUID(session))
    except (ValueError, TypeError, AttributeError):
        raise ghreview.Refused("invalid edit session")
    common = Path(_text("rev-parse", "--path-format=absolute", "--git-common-dir")).resolve()
    return common, common / "canopy-edits" / session


def _save(path, data):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w") as out:
        json.dump(data, out)
        out.flush()
        os.fsync(out.fileno())
    os.replace(temporary, path)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _load(root):
    try:
        session = json.loads((root / "session.json").read_text())
        if session.get("session") != root.name:
            raise ValueError("session identity changed")
        return session
    except (OSError, ValueError):
        raise ghreview.Refused("the edit session is unavailable; its checkout has been preserved")


def _validate(common, root, session):
    checkout = root / "checkout"
    if not checkout.is_dir() or not Path(session["gitdir"]).is_dir():
        raise ghreview.Refused(f"the edit checkout is unavailable; its frozen save is preserved in {root}")
    gitdir = _text("rev-parse", "--absolute-git-dir", cwd=checkout)
    if (session["repo"] != str(common) or session["identity"] != _identity(common)
            or session["checkoutIdentity"] != _identity(checkout)
            or session["gitdir"] != gitdir or session["gitdirIdentity"] != _identity(gitdir)
            or Path(_text("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=checkout)).resolve() != common):
        raise ghreview.Refused(f"the edit checkout was replaced; edits are saved in {checkout}")
    head = subprocess.run(["git", "symbolic-ref", "-q", "HEAD"], cwd=checkout, capture_output=True)
    if head.returncode != 1 or _text("rev-parse", "HEAD", cwd=checkout) != session["baseSha"]:
        raise ghreview.Refused(f"the edit checkout's Git state changed; edits are saved in {checkout}")
    if _text("write-tree", cwd=checkout) != _text("rev-parse", f"{session['expectedTip']}^{{tree}}"):
        raise ghreview.Refused(f"the edit checkout's index changed; edits are saved in {checkout}")


@reviewdesk._guarded
def prepare(req, data):
    _require_epoch(data)
    session = data.get("session")
    common, root = _root(session)
    session = root.name
    root.mkdir(parents=True, exist_ok=True)
    with (root / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        branch, tip, base = (data.get(key) or "" for key in ("branch", "expectedTip", "baseSha"))
        _git("check-ref-format", f"refs/heads/{branch}")
        if (root / "session.json").exists():
            saved = _load(root)
            if (saved["branch"], saved["expectedTip"], saved["baseSha"]) != (branch, tip, base):
                raise ghreview.Refused("that session belongs to another revision")
            if saved.get("operation"):
                raise ghreview.Refused("that edit session already owns a frozen save")
            _validate(common, root, saved)
            return reviewdesk._send(req, 200, {"ok": True, "epoch": _epoch(), "session": session, "dir": str(root / "checkout"), "sha": tip, "baseSha": base})
        if not tip or _text("rev-parse", f"refs/heads/{branch}") != tip:
            raise ghreview.Refused("the branch moved before the edit session opened")
        if not base or _text("rev-parse", "--verify", f"{base}^{{commit}}") != base:
            raise ghreview.Refused("the comparison revision is unavailable")
        checkout = root / "checkout"
        _git("worktree", "add", "--detach", "--no-checkout", str(checkout), base)
        _git("read-tree", "--reset", "-u", tip, cwd=checkout)
        _git("worktree", "lock", "--reason", "Canopy edit session", str(checkout))
        for name in ("node_modules", ".gen"):
            source = Path(ctx.repo_cwd()) / name
            ignored = subprocess.run(["git", "check-ignore", "-q", name], cwd=checkout).returncode == 0
            if ignored and source.exists() and not (checkout / name).exists():
                (checkout / name).symlink_to(source, target_is_directory=True)
        gitdir = _text("rev-parse", "--absolute-git-dir", cwd=checkout)
        saved = {"session": session, "openedEpoch": _epoch(), "repo": str(common), "identity": _identity(common), "repoName": ctx.repo_name(),
                 "branch": branch, "expectedTip": tip, "baseSha": base, "checkoutIdentity": _identity(checkout),
                 "gitdir": gitdir, "gitdirIdentity": _identity(gitdir)}
        _save(root / "session.json", saved)
        reviewdesk._send(req, 200, {"ok": True, "epoch": _epoch(), "session": session, "dir": str(checkout), "sha": tip, "baseSha": base})


def _files(base, tip, paths):
    files = []
    for path in paths:
        args = ("--no-ext-diff", "--no-textconv", "--no-renames", "--no-color", base, tip, "--", path)
        raw = _git("diff", "-p", *args).decode(errors="replace")
        if not raw:
            continue
        patch = _git("diff", "-w", "-p", *args).decode(errors="replace")
        stats = _git("diff", "--numstat", "-z", *(() if not patch else ("-w",)), *args).split(b"\t", 2)
        add, delete = [int(value) if value.isdigit() else 0 for value in stats[:2]]
        files.append({"path": path, "patch": patch or raw, "add": add, "del": delete, "wsOnly": not bool(patch)})
    return files


def _affected(base, tip, new, changed):
    renames = []
    for revision in (tip, new):
        entries = _git("diff", "--name-status", "--find-renames", "-z", base, revision).split(b"\0")
        i = 0
        while i < len(entries) and entries[i]:
            if entries[i].startswith(b"R"):
                renames.append({os.fsdecode(entries[i + 1]), os.fsdecode(entries[i + 2])})
                i += 3
            else:
                i += 2
    affected = set(changed)
    while True:
        expanded = affected.union(*(pair for pair in renames if pair & affected))
        if expanded == affected:
            return sorted(affected)
        affected = expanded


def _freeze(root, session, operation):
    checkout = root / "checkout"
    index = root / "snapshot-index"
    env = {**os.environ, "GIT_INDEX_FILE": str(index)}
    shutil.copyfile(Path(session["gitdir"]) / "index", index)
    _git("add", "-A", "--", ".", cwd=checkout, env=env)
    tree = _text("write-tree", cwd=checkout, env=env)
    tip = session["expectedTip"]
    paths = [os.fsdecode(path) for path in _git("diff-tree", "--no-commit-id", "--name-only", "--no-renames", "-r", "-z", tip, tree).split(b"\0") if path]
    receipt = {"ok": True, "session": session["session"], "operation": operation, "repo": session["repoName"],
               "branch": session["branch"], "expectedTip": tip, "baseSha": session["baseSha"], "paths": paths}
    if not paths:
        receipt.update(nothing=True, sha=tip)
    else:
        message = reviewdesk._edit_message(session["branch"], tip, str(checkout), paths[0])
        new = reviewdesk._commit_tree(tip, tree, message)
        _git("update-ref", f"refs/canopy/edits/{session['session']}", new)
        paths = _affected(session["baseSha"], tip, new, paths)
        requires = subprocess.run(["git", "config", "--get-all", f"branch.{session['branch']}.stack-requires"],
                                  cwd=ctx.repo_cwd(), capture_output=True).stdout.strip()
        subject, author, date, body = _text("show", "-s", "--format=%s%x00%an%x00%ad%x00%b", "--date=short", new).split("\0", 3)
        receipt.update(sha=new, tree=tree, message=message.strip(), paths=paths, incremental=not bool(requires), files=_files(session["baseSha"], new, paths),
                       history={"sha": new, "subject": subject, "body": body, "author": author, "date": date, "own": True, "pushed": False})
    session.update(operation=operation, receipt=receipt, state="prepared")
    _save(root / "session.json", session)
    return receipt


def _attached(branch):
    path = None
    for line in _text("worktree", "list", "--porcelain").splitlines():
        if line.startswith("worktree "):
            path = line[9:]
        elif line == f"branch refs/heads/{branch}":
            return path


def _advance(session):
    branch, tip, new = session["branch"], session["expectedTip"], session["receipt"]["sha"]
    current = _text("rev-parse", f"refs/heads/{branch}")
    if current == new:
        return
    if current != tip:
        raise ghreview.Refused("the branch moved while you edited; the session's checkout and frozen save are preserved")
    run = push.gate_run(branch)
    if run and run.alive():
        raise ghreview.Refused("a gates run owns the branch's worktree; the frozen save is preserved")
    checkout = _attached(branch)
    if not checkout:
        _git("update-ref", "-m", f"canopy edit {session['session']}", f"refs/heads/{branch}", new, tip)
        return
    process = subprocess.Popen(["git", "update-ref", "--stdin"], cwd=checkout,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        process.stdin.write(f"start\nupdate refs/heads/{branch} {new} {tip}\nprepare\n")
        process.stdin.flush()
        if process.stdout.readline() != "start: ok\n" or process.stdout.readline() != "prepare: ok\n":
            raise ghreview.Refused("the branch could not be locked; the frozen save is preserved")
        if _text("symbolic-ref", "HEAD", cwd=checkout) != f"refs/heads/{branch}":
            raise ghreview.Refused("the branch's worktree changed; the frozen save is preserved")
        _git("read-tree", "-m", "-u", tip, new, cwd=checkout)
        process.stdin.write("commit\n")
        process.stdin.flush()
        if process.stdout.readline() != "commit: ok\n":
            raise ghreview.Refused("the ref transaction failed; the checkout and frozen save are preserved")
    finally:
        process.stdin.close()
        process.wait()
        process.stdout.close()
        process.stderr.close()


def _retire(root, session):
    checkout = root / "checkout"
    ignored = [os.fsdecode(path) for path in _git("ls-files", "--others", "--ignored", "--exclude-standard", "-z", cwd=checkout).split(b"\0") if path]
    if any(path not in ("node_modules", ".gen") or not (checkout / path).is_symlink() for path in ignored):
        return
    _git("read-tree", session["receipt"]["sha"], cwd=checkout)
    _git("update-ref", "--no-deref", "HEAD", session["receipt"]["sha"], cwd=checkout)
    _git("worktree", "unlock", str(checkout))
    _git("worktree", "remove", str(checkout))


def _cleanup(repo, root):
    ctx.set_repo(repo)
    try:
        with (root / "lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return
            session = _load(root)
            if session.get("state") == "committed" and (root / "checkout").is_dir():
                _retire(root, session)
    except (ghreview.Refused, OSError) as error:
        ctx.log(f"edit session {root.name}: checkout preserved: {error}")
    finally:
        ctx.clear_repo()


def _cleanup_later(root):
    threading.Thread(target=_cleanup, args=(ctx.repo_cwd(), root), daemon=True).start()


@reviewdesk._guarded
def commit(req, data):
    _require_epoch(data)
    common, root = _root(data.get("session"))
    if not root.is_dir():
        raise ghreview.Refused("unknown edit session")
    with (root / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        session = _load(root)
        if session["repo"] != str(common) or session["identity"] != _identity(common):
            raise ghreview.Refused("that edit session belongs to another repository")
        if data.get("branch") != session["branch"] or data.get("expectedTip") != session["expectedTip"]:
            raise ghreview.Refused("the save doesn't match its edit session")
        operation = data.get("operation")
        try:
            operation = str(uuid.UUID(operation))
        except (ValueError, TypeError, AttributeError):
            raise ghreview.Refused("invalid save operation")
        if session.get("operation") and operation != session["operation"]:
            raise ghreview.Refused("that session already owns a frozen save")
        if session.get("state") == "committed":
            receipt = session["receipt"]
        else:
            _validate(common, root, session)
            receipt = session.get("receipt") or _freeze(root, session, operation)
            if not receipt.get("nothing"):
                _advance(session)
            session["state"] = "committed"
            _save(root / "session.json", session)
        reviewdesk._send(req, 200, {**receipt, "epoch": _epoch()})
    _cleanup_later(root)
