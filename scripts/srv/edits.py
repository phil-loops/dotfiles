"""Owned editor checkouts, frozen saves, and revision-qualified commit receipts."""
import fcntl
from concurrent.futures import Future, ThreadPoolExecutor
from contextlib import nullcontext
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import threading
import uuid

from . import ctx, editartifacts, editlease, editprojection, ghreview, push, reviewdesk

_ROOTS = {}
_VALID_BRANCHES = set()
_PRIMING = {}
_PRIME_LOCK = threading.Lock()
_LOCK_REASON = "Canopy edit session"


class _Warmup(Future):
    def __init__(self):
        super().__init__()
        self.phase = "building"
        self.claimed = None
        self.root = None
        self.claim = threading.Event()


def _stamp(path):
    stat = os.stat(path)
    return [stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns]


def _common():
    repo = Path(ctx.repo_cwd()).resolve()
    marker = repo / ".git"
    stamp = _identity(marker) if marker.is_dir() else _stamp(marker)
    cached = _ROOTS.get(str(repo))
    if cached and cached[0] == stamp:
        return cached[1]
    common = Path(_text("rev-parse", "--path-format=absolute", "--git-common-dir")).resolve()
    _ROOTS[str(repo)] = stamp, common
    return common


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
    common = _common()
    return common, common / "canopy-edits" / session


_save = editlease.write_record


def _transition(root, session, state):
    previous = session.get("state", "editing")
    allowed = {"preparing": {"editing", "cached"}, "editing": {"prepared"},
               "prepared": {"landing", "committed"}, "landing": {"landing", "committed"}, "committed": {"committed"}}
    if state != previous and state not in allowed.get(previous, set()):
        raise ghreview.Refused(f"the workspace cannot move from {previous} to {state}; its files are preserved")
    session.update(workspaceVersion=1, state=state)
    _save(root / "session.json", session)


def _load(root):
    try:
        session = json.loads((root / "session.json").read_text())
        if not isinstance(session, dict) or session.get("session") != root.name:
            raise ValueError("session identity changed")
        if session.get("workspaceVersion", 1) != 1:
            raise ValueError("unsupported workspace version")
        return session
    except (OSError, ValueError):
        raise ghreview.Refused("the edit session is unavailable; its checkout has been preserved")


def _checkout(root, session):
    return Path(session.get("checkout") or root / "checkout")


def _validate(common, root, session):
    checkout = _checkout(root, session)
    if not checkout.is_dir() or not Path(session["gitdir"]).is_dir():
        raise ghreview.Refused(f"the edit checkout is unavailable; its frozen save is preserved in {root}")
    gitdir = session["gitdir"]
    if (session["repo"] != str(common) or session["identity"] != _identity(common)
            or session["checkoutIdentity"] != _identity(checkout)
            or session["gitdirIdentity"] != _identity(gitdir)
            or (checkout / ".git").read_text().strip() != f"gitdir: {gitdir}"):
        raise ghreview.Refused(f"the edit checkout was replaced; edits are saved in {checkout}")
    actual_common = (Path(gitdir) / (Path(gitdir) / "commondir").read_text().strip()).resolve()
    if actual_common != common or (Path(gitdir) / "HEAD").read_text().strip() != session["baseSha"]:
        raise ghreview.Refused(f"the edit checkout's Git state changed; edits are saved in {checkout}")
    if session.get("indexStamp") != _stamp(Path(gitdir) / "index"):
        expected_tree = session.get("expectedTree") or _text("rev-parse", f"{session['expectedTip']}^{{tree}}")
        if _text("write-tree", cwd=checkout) != expected_tree:
            raise ghreview.Refused(f"the edit checkout's index changed; edits are saved in {checkout}")


@reviewdesk._guarded
def prepare(req, data):
    return _prepare(req, data)


def _prepared(req, root, saved, data):
    if saved.get("leaseProtocol") != data.get("leaseProtocol"):
        raise ghreview.Refused("that workspace has a different attachment protocol; its files are preserved")
    if saved.get("leaseProtocol") == 1 and _text("rev-parse", f"refs/heads/{saved['branch']}") != saved["expectedTip"]:
        raise ghreview.Refused("the branch moved since that workspace opened; its files are preserved")
    def ready(path, metadata):
        if metadata.get("state") == "preparing":
            _transition(root, metadata, "editing")
        else:
            _save(path, metadata)
    attachment = editlease.issue(root, saved, save=ready)
    body = {"ok": True, "epoch": _epoch(), "session": saved["session"], "dir": str(_checkout(root, saved)),
            "sha": saved["expectedTip"], "baseSha": saved["baseSha"]}
    if attachment:
        body["attachment"] = attachment
    if saved.get("viewOwner"):
        body["viewOwner"] = saved["viewOwner"]
    return reviewdesk._send(req, 200, body)


def _entry(data):
    entry = data.get("entry")
    if (not isinstance(entry, dict) or not isinstance(entry.get("path"), str)
            or any(part in ("", ".", "..") for part in entry["path"].split("/"))
            or any(type(entry.get(key)) is not int or entry[key] <= 0 for key in ("line", "col"))):
        raise ghreview.Refused("the editor needs a file position inside its workspace")
    return {key: entry[key] for key in ("path", "line", "col")}


def _view_owner(data):
    try:
        return str(uuid.UUID(data["viewOwner"]))
    except (KeyError, ValueError, TypeError, AttributeError):
        raise ghreview.Refused("the review workspace needs its original owner")


def _prepare(req, data, cache=False):
    _require_epoch(data)
    owner = _view_owner(data) if "viewOwner" in data else None
    if owner and (cache or data.get("leaseProtocol") != 1):
        raise ghreview.Refused("a review workspace needs a leased editor attachment")
    session = data.get("session")
    common, root = _root(session)
    session = root.name
    root.mkdir(parents=True, exist_ok=True)
    with (root / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        branch, tip, base = (data.get(key) or "" for key in ("branch", "expectedTip", "baseSha"))
        if (root / "session.json").exists():
            saved = _load(root)
            if saved.get("state") == "released":
                raise ghreview.Refused("that review released its workspace; its remaining files are preserved")
            if saved.get("viewOwner") and not saved.get("entered") and saved["viewOwner"] != owner:
                raise ghreview.Refused("that workspace belongs to another review")
            if saved.get("kind") == "cache":
                raise ghreview.Refused("that checkout belongs to the editor cache")
            if (saved["branch"], saved["expectedTip"], saved["baseSha"]) != (branch, tip, base):
                raise ghreview.Refused("that session belongs to another revision")
            if saved.get("operation"):
                raise ghreview.Refused("that edit session already owns a frozen save")
            if saved.get("state") == "preparing":
                raise ghreview.Refused(f"workspace preparation was interrupted; its files are preserved in {_checkout(root, saved)}")
            with editlease.available(root, saved):
                _validate(common, root, saved)
            return _prepared(req, root, saved, data)
        if branch not in _VALID_BRANCHES:
            _git("check-ref-format", f"refs/heads/{branch}")
            _VALID_BRANCHES.add(branch)
        if not tip or not base:
            raise ghreview.Refused("the edit needs its full tip and comparison revision")
        revisions = _text("rev-parse", "--revs-only", "--end-of-options", f"refs/heads/{branch}", f"{base}^{{commit}}").splitlines()
        if revisions != [tip, base]:
            raise ghreview.Refused("the branch or comparison revision changed before the edit session opened")
        checkout = root / "checkout"
        if os.path.lexists(checkout):
            raise ghreview.Refused(f"the earlier preparation left a checkout; it is preserved in {checkout}")
        saved = {"workspaceVersion": 1, "state": "preparing", "session": session, "kind": "cache" if cache else "editor",
                 "workspaceIdentity": _identity(root),
                 "checkout": str(checkout), "openedEpoch": _epoch(), "repo": str(common), "identity": _identity(common),
                 "repoName": ctx.repo_name(), "branch": branch, "expectedTip": tip, "baseSha": base}
        if owner:
            saved["viewOwner"] = owner
        if not cache and data.get("leaseProtocol") is not None:
            if type(data["leaseProtocol"]) is not int or data["leaseProtocol"] != 1:
                raise ghreview.Refused("unsupported editor attachment protocol")
            saved.update(leaseProtocol=1, entry=_entry(data))
            editlease.initialize(root, saved)
        _save(root / "session.json", saved)
        priming = None
        reserved = False
        if not cache:
            with _PRIME_LOCK:
                priming = _PRIMING.get(str(common))
                if priming and priming.phase in ("building", "ready") and priming.claimed is None:
                    priming.claimed = root.name
                    priming.claim.set()
                    reserved = True
            if priming:
                priming.result(timeout=120)
        reused = _take_reserved(common, root, priming.root) if reserved and priming.result() else False
        if not reused and not cache:
            reused = _take(common, root)
        if reused:
            if reused != tip:
                _git("-c", "checkout.workers=4", "read-tree", "-m", "-u", reused, tip, cwd=checkout)
            _git("update-ref", "--no-deref", "HEAD", base, cwd=checkout)
        else:
            _git("worktree", "add", "--detach", "--no-checkout", str(checkout), base)
            _git("-c", "checkout.workers=4", "read-tree", "--reset", "-u", tip, cwd=checkout)
        if not reused:
            _git("worktree", "lock", "--reason", _LOCK_REASON, str(checkout))
        for name in ("node_modules", ".gen"):
            source = Path(ctx.repo_cwd()) / name
            if source.exists() and not (checkout / name).exists():
                if subprocess.run(["git", "check-ignore", "-q", name], cwd=checkout).returncode == 0:
                    (checkout / name).symlink_to(source, target_is_directory=True)
        gitdir = str((checkout / (checkout / ".git").read_text().strip().removeprefix("gitdir: ")).resolve())
        parent = subprocess.run(["git", "config", f"branch.{branch}.stack-parent"], cwd=ctx.repo_cwd(), capture_output=True, text=True).stdout.strip() or "main"
        metadata = subprocess.run(["git", "rev-parse", "--revs-only", "--end-of-options", f"{tip}^{{tree}}", f"{parent}^{{commit}}"], cwd=ctx.repo_cwd(), capture_output=True, text=True)
        values = metadata.stdout.strip().splitlines()
        expected_tree = values[0]
        parent_sha = values[1] if metadata.returncode == 0 and len(values) == 2 else ""
        saved.update(checkoutIdentity=_identity(checkout),
                     gitdir=gitdir, gitdirIdentity=_identity(gitdir), expectedTree=expected_tree, parentSha=parent_sha,
                     indexStamp=_stamp(Path(gitdir) / "index"))
        if owner:
            try:
                _warm_index(root, saved)
            except (ghreview.Refused, OSError) as error:
                ctx.log(f"review workspace {root.name}: index preparation skipped: {error}")
        if saved.get("leaseProtocol") != 1:
            _transition(root, saved, "cached" if cache else "editing")
        _prepared(req, root, saved, data)
    if not cache and not owner:
        _warm_later(root)


@reviewdesk._guarded
def prime(req, data):
    if "epoch" in data:
        _require_epoch(data)
    data = {**data, "epoch": _epoch()}
    common = _common()
    with _PRIME_LOCK:
        current = _PRIMING.get(str(common))
        if current and not current.done():
            return reviewdesk._send(req, 200, {"ok": True})
        try:
            ready = json.loads((common / "canopy-edits/ready.json").read_text())
        except (OSError, ValueError):
            ready = {}
        if ready.get("session"):
            return reviewdesk._send(req, 200, {"ok": True})
        job = _Warmup()
        _PRIMING[str(common)] = job
        threading.Thread(target=_prime, args=(ctx.repo_cwd(), common, data, job), daemon=True).start()
    reviewdesk._send(req, 200, {"ok": True})


def _prime(repo, common, data, job):
    ctx.set_repo(repo)
    try:
        session = str(uuid.uuid4())
        answer = reviewdesk._Answer()
        tip = data.get("expectedTip") or _text("rev-parse", "--verify", f"refs/heads/{data.get('branch') or ''}")
        _prepare(answer, {**data, "session": session, "expectedTip": tip, "baseSha": tip}, cache=True)
        if not answer.ok():
            raise ghreview.Refused(answer.data.get("err") or "editor cache preparation failed")
        _, root = _root(session)
        with _PRIME_LOCK:
            job.root = root
            job.phase = "ready"
        job.claim.wait(0.25)
        with _PRIME_LOCK:
            claimant = job.claimed
            job.phase = "claimed" if claimant else "parking"
        with (root / "lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            saved = _load(root)
            saved["state"] = "cached"
            if claimant:
                saved.update(checkoutState="reserved", reservedFor=claimant)
                _save(root / "session.json", saved)
            else:
                _park(root, saved, tip=tip)
        job.set_result(True)
    except Exception as error:
        ctx.log(f"editor cache preparation skipped: {error}")
        job.set_result(False)
    finally:
        with _PRIME_LOCK:
            if _PRIMING.get(str(common)) is job:
                del _PRIMING[str(common)]
        ctx.clear_repo()


def _take_reserved(common, root, source):
    """Transfer builder output reserved before it could enter the idle cache."""
    with (source / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        saved = _load(source)
        if saved.get("kind") != "cache" or saved.get("checkoutState") != "reserved" or saved.get("reservedFor") != root.name:
            raise ghreview.Refused("that prepared checkout belongs to another editor")
        _validate(common, source, saved)
        _git("worktree", "move", "--force", "--force", str(_checkout(source, saved)), str(root / "checkout"))
        saved["checkoutState"] = "released"
        _save(source / "session.json", saved)
        return saved["expectedTip"]


def _warm_index(root, session):
    checkout = _checkout(root, session)
    refreshed = subprocess.run(["git", "-c", "core.fsmonitor=false", "update-index", "--refresh"], cwd=checkout, capture_output=True)
    if refreshed.returncode not in (0, 1):
        return False
    _text("write-tree", cwd=checkout)
    index = Path(session["gitdir"]) / "index"
    stamp = _stamp(index)
    snapshot = root / "warm-index"
    shutil.copy2(index, snapshot)
    if stamp != _stamp(index):
        return False
    env = {**os.environ, "GIT_INDEX_FILE": str(snapshot)}
    if _text("write-tree", cwd=checkout, env=env) != session["expectedTree"]:
        return False
    session["indexStamp"] = stamp
    editartifacts.remember(root, session, "warm-index")
    return True


def _warm(repo, root):
    ctx.set_repo(repo)
    try:
        with (root / "lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            session = _load(root)
            if session.get("operation") or session.get("state") != "editing":
                return
            if _warm_index(root, session):
                _save(root / "session.json", session)
    except (ghreview.Refused, OSError) as error:
        ctx.log(f"edit session {root.name}: index warm-up skipped: {error}")
    finally:
        ctx.clear_repo()


def _warm_later(root):
    threading.Thread(target=_warm, args=(ctx.repo_cwd(), root), daemon=True).start()


def _files(base, tip, paths):
    files = []
    with ThreadPoolExecutor(max_workers=3, initializer=ctx.set_repo, initargs=(ctx.repo_cwd(),)) as pool:
        for path in paths:
            args = ("--no-ext-diff", "--no-textconv", "--no-renames", "--no-color", base, tip, "--", path)
            raw_result = pool.submit(_git, "diff", "-p", *args)
            patch_result = pool.submit(_git, "diff", "-w", "-p", *args)
            stats_result = pool.submit(_git, "diff", "--numstat", "-z", "-w", *args)
            raw = raw_result.result().decode(errors="replace")
            patch = patch_result.result().decode(errors="replace")
            stats = stats_result.result()
            if not raw:
                continue
            if not patch:
                stats = _git("diff", "--numstat", "-z", *args)
            add, delete = [int(value) if value.isdigit() else 0 for value in stats.split(b"\t", 2)[:2]]
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


def _capture(root, session):
    checkout = _checkout(root, session)
    index = root / "snapshot-index"
    env = {**os.environ, "GIT_INDEX_FILE": str(index)}
    shutil.copy2(Path(session["gitdir"]) / "index", index)
    _git("-c", "core.fsmonitor=false", "add", "-A", "--", ".", cwd=checkout, env=env)
    tree = _text("write-tree", cwd=checkout, env=env)
    tip = session["expectedTip"]
    paths = [os.fsdecode(path) for path in _git("diff-tree", "--no-commit-id", "--name-only", "--no-renames", "-r", "-z", tip, tree).split(b"\0") if path]
    editartifacts.remember(root, session, "snapshot-index")
    return tree, paths


def _freeze(root, session, operation):
    checkout = _checkout(root, session)
    tip = session["expectedTip"]
    tree, paths = _capture(root, session)
    receipt = {"ok": True, "session": session["session"], "operation": operation, "repo": session["repoName"],
               "branch": session["branch"], "expectedTip": tip, "baseSha": session["baseSha"], "paths": paths}
    if not paths:
        receipt.update(nothing=True, sha=tip)
    else:
        with ThreadPoolExecutor(max_workers=3, initializer=ctx.set_repo, initargs=(ctx.repo_cwd(),)) as pool:
            message_result = pool.submit(_message, session, tree, paths[0], checkout)
            paths_result = pool.submit(_affected, session["baseSha"], tip, tree, paths)
            requires_result = pool.submit(subprocess.run, ["git", "config", "--get-all", f"branch.{session['branch']}.stack-requires"],
                                          cwd=ctx.repo_cwd(), capture_output=True)
            paths = paths_result.result()
            files_result = pool.submit(_files, session["baseSha"], tree, paths)
            message = message_result.result()
            new = reviewdesk._commit_tree(tip, tree, message)
            anchor = pool.submit(_git, "update-ref", f"refs/canopy/edits/{session['session']}", new)
            history = pool.submit(_text, "show", "-s", "--format=%s%x00%an%x00%ad%x00%b", "--date=short", new)
            subject, author, date, body = history.result().split("\0", 3)
            anchor.result()
            receipt.update(sha=new, tree=tree, message=message.strip(), paths=paths,
                           incremental=not bool(requires_result.result().stdout.strip()), files=files_result.result(),
                           history={"sha": new, "subject": subject, "body": body, "author": author, "date": date, "own": True, "pushed": False})
    session.update(operation=operation, receipt=receipt)
    _transition(root, session, "prepared")
    return receipt


def _message(session, tree, path, checkout):
    fallback = f"edit {path.rsplit('/', 1)[-1]}\n"
    parent = session.get("parentSha")
    if not parent:
        return fallback if "parentSha" in session else reviewdesk._edit_message(session["branch"], session["expectedTip"], str(checkout), path)
    hunk = re.search(rb"^@@ -(\d+)", _git("diff", "-U0", session["expectedTip"], tree, "--", path), re.M)
    if not hunk:
        return fallback
    line = max(1, int(hunk.group(1)))
    blame = subprocess.run(["git", "blame", "--porcelain", "-L", f"{line},{line}",
                            f"{parent}..{session['expectedTip']}", "--", path], cwd=ctx.repo_cwd(), capture_output=True)
    lines = blame.stdout.decode(errors="replace").splitlines()
    if blame.returncode or "boundary" in lines or not lines:
        return fallback
    sha = lines[0].split()[0]
    if _git("for-each-ref", "--count=1", "--contains", sha, "refs/remotes").strip():
        return fallback
    subject = next((line[8:] for line in lines if line.startswith("summary ")), "")
    return (subject if subject.startswith("fixup! ") else "fixup! " + subject) + "\n" if subject else fallback


def _attached(branch):
    path = None
    for line in _text("worktree", "list", "--porcelain").splitlines():
        if line.startswith("worktree "):
            path = line[9:]
        elif line == f"branch refs/heads/{branch}":
            return path


def _advance(session):
    root = _root(session["session"])[1]
    branch, tip, new = session["branch"], session["expectedTip"], session["receipt"]["sha"]
    current = _text("rev-parse", f"refs/heads/{branch}")
    committed = current == new
    if committed and (not session.get("projection") or session["projection"].get("phase") == "index-applied"):
        return
    if current not in (tip, new):
        raise ghreview.Refused("the branch moved while you edited; the session's checkout and frozen save are preserved")
    run = push.gate_run(branch)
    if run and run.alive():
        raise ghreview.Refused("a gates run owns the branch's worktree; the frozen save is preserved")
    checkout = _attached(branch)
    if session.get("projection") and checkout != session["projection"]["checkout"]:
        raise ghreview.Refused("the branch's attached checkout changed; the frozen save and recovery journal are preserved")
    if not checkout:
        _transition(root, session, "landing")
        _git("update-ref", "-m", f"canopy edit {session['session']}", f"refs/heads/{branch}", new, tip)
        return
    with editprojection.Projection(root, session, checkout, git=_git, save=_save) as projection:
        process = subprocess.Popen(["git", "update-ref", "--stdin"], cwd=checkout,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            process.stdin.write(f"start\nupdate refs/heads/{branch} {new} {current}\nprepare\n")
            process.stdin.flush()
            if process.stdout.readline() != "start: ok\n" or process.stdout.readline() != "prepare: ok\n":
                raise ghreview.Refused("the branch could not be locked; the frozen save is preserved")
            projection.apply(committed=committed)
            projection.head()
            process.stdin.write("commit\n")
            process.stdin.flush()
            if process.stdout.readline() != "commit: ok\n":
                raise ghreview.Refused("the ref transaction failed; the checkout and frozen save are preserved")
            projection.install()
        finally:
            process.stdin.close()
            process.wait()
            process.stdout.close()
            process.stderr.close()


def _retire(root, session):
    checkout = _checkout(root, session)
    _validate_parked(root, session)
    if not _clean(checkout):
        return False
    _git("worktree", "unlock", str(checkout))
    _git("worktree", "remove", str(checkout))
    return True


def _clean(checkout):
    for entry in _git("status", "--porcelain=v1", "-z", "--ignored=matching", "--untracked-files=all", cwd=checkout).split(b"\0"):
        if not entry:
            continue
        path = os.fsdecode(entry[3:])
        if not (entry[:3] == b"!! " and path in ("node_modules", ".gen") and (checkout / path).is_symlink()):
            return False
    return True


def _unmodified(checkout):
    try:
        _git("diff-files", "--quiet", "--", cwd=checkout)
    except ghreview.Refused:
        return False
    for entry in _git("ls-files", "--others", "--directory", "-z", "--", cwd=checkout).split(b"\0"):
        path = os.fsdecode(entry).rstrip("/")
        if path and not (path in ("node_modules", ".gen") and (checkout / path).is_symlink()):
            return False
    return True


def _validate_parked(root, session):
    tip = session.get("cacheTip") or session.get("receipt", {}).get("sha")
    return _validate(Path(session["repo"]), root, {**session, "baseSha": tip, "expectedTip": tip,
        "expectedTree": session.get("cacheTree") or session.get("receipt", {}).get("tree") or session.get("expectedTree"),
        "indexStamp": session.get("parkedStamp")})


def _take(common, root):
    directory = common / "canopy-edits"
    with (directory / "ready.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            ready = json.loads((directory / "ready.json").read_text())
        except (OSError, ValueError):
            return False
        if not ready.get("tip"):
            return False
        tip = ready["tip"]
        _save(directory / "ready.json", {})
    try:
        _, previous = _root(ready.get("session"))
        with (previous / "lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            session = _load(previous)
            checkout = _checkout(previous, session)
            if (session.get("checkoutState") != "parked" or session["repo"] != str(common)
                    or session["identity"] != _identity(common) or (session.get("cacheTip") or session.get("receipt", {}).get("sha")) != tip or not checkout.is_dir()):
                return False
            _validate_parked(previous, session)
            if not _clean(checkout):
                session["checkoutState"] = "preserved"
                _save(previous / "session.json", session)
                return False
            if (Path(session["gitdir"]) / "HEAD").read_text().strip() != tip:
                return False
            _git("worktree", "move", "--force", "--force", str(checkout), str(root / "checkout"))
            session["checkoutState"] = "released"
            _save(previous / "session.json", session)
            return tip
    except (ghreview.Refused, OSError) as error:
        ctx.log(f"edit checkout cache skipped: {error}")
        return False


def _park(root, session, tip=None):
    checkout = _checkout(root, session)
    _validate(Path(session["repo"]), root, session)
    tip = tip or session["receipt"]["sha"]
    if session.get("kind") != "cache":
        _git("read-tree", tip, cwd=checkout)
        _git("update-ref", "--no-deref", "HEAD", tip, cwd=checkout)
    if not _clean(checkout):
        return
    session["checkoutState"] = "parked"
    session["cacheTip"] = tip
    session["cacheTree"] = session.get("receipt", {}).get("tree") or session["expectedTree"]
    session["parkedStamp"] = _stamp(Path(session["gitdir"]) / "index")
    _save(root / "session.json", session)
    directory = root.parent
    with (directory / "ready.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            previous = json.loads((directory / "ready.json").read_text())
        except (OSError, ValueError):
            previous = {}
        _save(directory / "ready.json", {"session": session["session"], "tip": tip})
    if previous.get("session") and previous["session"] != session["session"]:
        _, old = _root(previous["session"])
        threading.Thread(target=_evict, args=(ctx.repo_cwd(), old), daemon=True).start()


def _evict(repo, root):
    ctx.set_repo(repo)
    try:
        with (root / "lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            session = _load(root)
            if session.get("checkoutState") == "parked":
                removed = _retire(root, session)
                session["checkoutState"] = "retired" if removed else "preserved"
                _save(root / "session.json", session)
    except (ghreview.Refused, OSError) as error:
        ctx.log(f"edit checkout eviction skipped: {error}")
    finally:
        ctx.clear_repo()


def _cleanup(repo, root):
    ctx.set_repo(repo)
    try:
        with (root / "lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return
            session = _load(root)
            if session.get("state") == "committed":
                common = _common()
                if root != common / "canopy-edits" / session["session"] or session["repo"] != str(common) or session["identity"] != _identity(common):
                    raise ghreview.Refused("the workspace belongs to another repository; its files are preserved")
                with editlease.available(root, session):
                    try:
                        if not session.get("checkoutState") and _checkout(root, session).is_dir():
                            _park(root, session)
                    finally:
                        editartifacts.collect(root, session, save=_save)
    except (ghreview.Refused, OSError) as error:
        ctx.log(f"edit session {root.name}: checkout preserved: {error}")
    finally:
        ctx.clear_repo()


def _cleanup_later(root):
    threading.Thread(target=_cleanup, args=(ctx.repo_cwd(), root), daemon=True).start()


@reviewdesk._guarded
def release(req, data):
    owner = _view_owner(data)
    common, root = _root(data.get("session"))
    root.mkdir(parents=True, exist_ok=True)
    with (root / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if (root / "session.json").exists():
            saved = _load(root)
            if (saved.get("viewOwner") != owner or saved["repo"] != str(common) or saved["identity"] != _identity(common)):
                raise ghreview.Refused("that workspace belongs to another review; its files are preserved")
            if saved.get("entered") or saved.get("operation"):
                return reviewdesk._send(req, 200, {"ok": True, "preserved": True})
            with editlease.available(root, saved):
                saved["state"] = "released"
                _save(root / "session.json", saved)
        else:
            if os.path.lexists(root / "checkout"):
                raise ghreview.Refused("an unrecorded checkout exists; its files are preserved")
            _save(root / "session.json", {"workspaceVersion": 1, "session": root.name, "kind": "editor", "state": "released",
                  "viewOwner": owner, "repo": str(common), "identity": _identity(common)})
    reviewdesk._send(req, 200, {"ok": True, "released": True})
    _release_later(root)


def _release_checkout(repo, root):
    ctx.set_repo(repo)
    try:
        with (root / "lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            saved = _load(root)
            common = _common()
            if (saved.get("state") != "released" or not saved.get("viewOwner") or saved.get("entered") or saved.get("operation")
                    or saved["repo"] != str(common) or saved["identity"] != _identity(common)):
                return
            checkout = _checkout(root, saved)
            if not checkout.exists():
                editartifacts.collect(root, saved, save=_save)
                return
            if root.is_symlink() or checkout.is_symlink() or saved.get("workspaceIdentity") != _identity(root):
                raise ghreview.Refused("the review workspace was replaced; its files are preserved")
            if not all(key in saved for key in ("gitdir", "checkoutIdentity", "gitdirIdentity", "indexStamp")):
                raise ghreview.Refused("review preparation was interrupted; its files are preserved")
            with editlease.available(root, saved):
                if saved.get("indexStamp") != _stamp(Path(saved["gitdir"]) / "index"):
                    raise ghreview.Refused("the unused review's index changed; its files are preserved")
                head = (Path(saved["gitdir"]) / "HEAD").read_text().strip()
                validation = {**saved, "baseSha": head} if head == saved["expectedTip"] else saved
                _validate(common, root, validation)
                if _unmodified(checkout):
                    _git("update-ref", "--no-deref", "HEAD", saved["expectedTip"], head, cwd=checkout)
                    locked = Path(saved["gitdir"]) / "locked"
                    if locked.exists():
                        if locked.is_symlink() or locked.read_text().strip() != _LOCK_REASON:
                            raise ghreview.Refused("another operation locked the review checkout; its files are preserved")
                        _git("worktree", "unlock", str(checkout))
                    _git("worktree", "remove", str(checkout))
                    saved["checkoutState"] = "retired"
                else:
                    saved["checkoutState"] = "preserved"
                _save(root / "session.json", saved)
                editartifacts.collect(root, saved, save=_save)
    except (ghreview.Refused, OSError) as error:
        ctx.log(f"review workspace {root.name}: checkout preserved: {error}")
    finally:
        ctx.clear_repo()


def _release_later(root):
    threading.Thread(target=_release_checkout, args=(ctx.repo_cwd(), root), daemon=True).start()


@reviewdesk._guarded
def commit(req, data):
    return _commit(req, data)


@reviewdesk._guarded
def recover(req, data):
    return _commit(req, data, frozen=True)


def _commit(req, data, frozen=False):
    _require_epoch(data)
    common, root = _root(data.get("session"))
    if not root.is_dir():
        raise ghreview.Refused("unknown edit session")
    with (root / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        session = _load(root)
        if session.get("kind") == "cache":
            raise ghreview.Refused("that checkout belongs to the editor cache")
        if session.get("state") == "preparing":
            raise ghreview.Refused("workspace preparation was interrupted; its files are preserved")
        if session.get("state") == "released":
            raise ghreview.Refused("that review released its workspace; its files are preserved")
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
        if frozen and not session.get("receipt"):
            raise ghreview.Refused("that workspace has no frozen save to recover")
        if session.get("leaseProtocol") == 1 and not session.get("receipt"):
            if data.get("attachment") != session.get("attachment", {}).get("token"):
                raise ghreview.Refused("that attachment was superseded; the current editor workspace is preserved")
        with (nullcontext() if session.get("receipt") else editlease.available(root, session)):
            if session.get("state") == "committed":
                receipt = session["receipt"]
            else:
                receipt = session.get("receipt")
                if not receipt:
                    _validate(common, root, session)
                    receipt = _freeze(root, session, operation)
                if not receipt.get("nothing"):
                    _advance(session)
                _transition(root, session, "committed")
        reviewdesk._send(req, 200, {**receipt, "epoch": _epoch()})
    _cleanup_later(root)


@reviewdesk._guarded
def workspaces(req, data):
    _require_epoch(data)
    common = _common()
    result = []
    for root in sorted((common / "canopy-edits").glob("*/session.json")):
        if root.parent.is_symlink():
            continue
        try:
            session = _load(root.parent)
            phase = session.get("state", "editing")
            if phase == "released" or (session.get("viewOwner") and not session.get("entered")):
                continue
            if (session.get("kind") == "cache" or session["repo"] != str(common) or session["identity"] != _identity(common)
                    or (data.get("branch") and session["branch"] != data["branch"])):
                continue
            if phase == "committed" and not data.get("completed"):
                continue
            result.append({"session": session["session"], "branch": session["branch"], "expectedTip": session["expectedTip"],
                           "baseSha": session["baseSha"], "state": phase, "dir": str(_checkout(root.parent, session)),
                           "operation": session.get("operation"), "sha": session.get("receipt", {}).get("sha"),
                           "message": session.get("receipt", {}).get("message"),
                           "projection": session.get("projection", {}).get("phase"), "retryable": bool(session.get("receipt")),
                           "resumable": editlease.resumable(root.parent, session), "entry": session.get("entry")})
        except (ghreview.Refused, OSError, KeyError) as error:
            ctx.log(f"editor workspace unavailable: {root.parent}: {error}")
    return reviewdesk._send(req, 200, {"ok": True, "epoch": _epoch(), "workspaces": result})
