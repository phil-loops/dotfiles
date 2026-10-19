"""Durable priority queue sharing tsc-turn's machine-wide slot directories."""
import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid


@contextmanager
def locked(root):
    root.mkdir(parents=True, exist_ok=True)
    with (root / "scheduler.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


ORPHANED_SLOT_GRACE_SECONDS = 30


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, TypeError):
        return False


def orphaned(slot):
    """A slot with no pid file whose holder died between mkdir and writing it."""
    try:
        return time.time() - slot.stat().st_mtime > ORPHANED_SLOT_GRACE_SECONDS
    except OSError:
        return False


def save(path, record):
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(json.dumps(record))
    os.replace(temp, path)


def promote(path):
    path = Path(path)
    with locked(path.parent):
        try:
            record = json.loads(path.read_text())
        except (OSError, ValueError):
            path.with_suffix(".promoted").touch()
            return
        record["priority"] = 0
        save(path, record)


def claim(root, request):
    with locked(root):
        candidates = []
        for path in root.glob("*.queue.json"):
            try:
                record = json.loads(path.read_text())
                if not alive(record["pid"]):
                    path.unlink()
                elif record.get("state") == "queued":
                    candidates.append((record["priority"], record["created"], str(path), record))
            except (OSError, ValueError, KeyError):
                continue
        if not candidates or min(candidates, key=lambda c: c[:3])[2] != str(request):
            return None
        slot = root / "slot1"
        if slot.exists():
            try:
                holder = (slot / "pid").read_text().strip()
            except OSError:
                holder = ""
            if alive(holder) or (not holder and not orphaned(slot)):
                return None
            (slot / "pid").unlink(missing_ok=True)
            try:
                slot.rmdir()
            except OSError:
                return None
        try:
            slot.mkdir()
        except FileExistsError:
            return None
        (slot / "pid").write_text(str(os.getpid()))
        record = json.loads(request.read_text())
        record["state"] = "running"
        save(request, record)
        return slot


def tree_of(branch):
    result = subprocess.run(["git", "rev-parse", f"{branch}^{{tree}}"],
                            capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ""


def obsolete(progress):
    verdict = {"event": "result", "ok": False, "gates": [{
        "name": "queue", "ok": False, "ms": 0,
        "summary": "branch changed while queued — re-run gates for its current tree"}]}
    if progress:
        with Path(progress).open("a") as output:
            output.write(json.dumps(verdict) + "\n")
    print(json.dumps({k: v for k, v in verdict.items() if k != "event"}))


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--queue", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--tree", required=True)
    parser.add_argument("--priority", choices=("interactive", "background"), default="interactive")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("missing gate command")
    progress = command[command.index("--progress") + 1] if "--progress" in command else ""
    root = Path(args.queue).absolute()
    name = Path(progress).name if progress else str(uuid.uuid4())
    request = root / (name + ".queue.json")
    record = {"pid": os.getpid(), "priority": int(args.priority == "background"),
              "created": time.time_ns(), "state": "queued"}
    with locked(root):
        promotion = request.with_suffix(".promoted")
        if promotion.exists():
            record["priority"] = 0
            promotion.unlink()
        save(request, record)
    slot = None
    child = None

    def interrupted(signum, frame):
        raise InterruptedError("gate queue interrupted")

    signal.signal(signal.SIGTERM, interrupted)
    try:
        checked_at = 0
        while slot is None:
            if time.monotonic() - checked_at >= 2:
                checked_at = time.monotonic()
                if not args.tree or tree_of(args.branch) != args.tree:
                    obsolete(progress)
                    return 0
            slot = claim(root, request)
            if slot is None:
                time.sleep(0.2)
        if tree_of(args.branch) != args.tree:
            obsolete(progress)
            return 0
        env = dict(os.environ, STACK_GATES_PRIORITY=args.priority)
        child = subprocess.Popen(command, start_new_session=True, env=env)
        with locked(root):
            (slot / "pid").write_text(str(child.pid))
        return child.wait()
    except (InterruptedError, KeyboardInterrupt):
        if child is not None and child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
        return 130
    finally:
        with locked(root):
            request.unlink(missing_ok=True)
            request.with_suffix(".promoted").unlink(missing_ok=True)
            if slot is not None:
                holder = str(child.pid) if child is not None else str(os.getpid())
                if (slot / "pid").exists() and (slot / "pid").read_text() == holder:
                    (slot / "pid").unlink()
                    slot.rmdir()


if __name__ == "__main__":
    sys.exit(main())
