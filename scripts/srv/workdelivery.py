"""srv/workdelivery.py — the managed context-delivery adapter for the work journal (DESIGN.md round 25).

`dispatch` drains the journal's outbox. For each captured message bound for a worker it finds or
starts that worker's attempt at the message's work items, has the journal prepare and store the
packet (accumulated direction at one revision per item), and hands the worker an envelope that
carries the packet's full text — every instruction still in force, the latest literal message
included — so nothing depends on the worker fetching it. A private copy is written beside the
journal as an artifact; it is not the delivery.

Before anything is sent the row's earlier hand-offs are reconciled, so a crash after any durable
step never causes a second turn:

  acknowledged receipt   settle the row delivered; send nothing
  sending/uncertain      the worker may have it: settle uncertain; only a deliberate requeue resends
  failed or none         send

Receipts say only what the transport proved:

  claude-headless   the directly owned host: `claude -p` resumes the worker's session and takes
                    the envelope as one stream-json user message with a fresh uuid. Acknowledged
                    only when its stdout replays that message (--replay-user-messages) with the
                    same uuid and the exact text digest; session init is not acknowledgement.
                    Exiting nonzero before it is a failure; anything else is uncertain. An owned
                    wrapper records how each turn ended (succeeded, failed) in the journal, and a
                    turn whose process vanished without that record is observed as lost.
                    Compaction inside a turn reloads the same canonical packet through a
                    SessionStart hook matched to `compact`, passed with --settings for that
                    invocation only. The hook proves only that it emitted the text, so its receipt
                    is uncertain and supersedes the turn's: results after a compaction stay
                    unverified until the next confirmed turn. Resume needs no hook — every turn's
                    own envelope already carries the full packet.
  claude-say        legacy tmux typing: one JSON-escaped line. The helper's printout is not a
                    checked acknowledgement (it ignores tmux's exit status and may draft instead of
                    submitting), so these hand-offs are always uncertain and their results unverified.

Any other host is unsupported. A delivered turn is never a completion: nothing here reports one.
Executables are injected ($CANOPY_WORK_CLAUDE, $CANOPY_WORK_CLAUDE_SAY); tests use stubs.
"""
import fcntl
import json
import os
import re
import shlex
import subprocess
import sys
import time
import uuid

from . import workjournal as wj

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SESSION = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


class Failed(Exception):
    """The transport proved the hand-off did not happen."""


def _state_dir(journal, name):
    d = os.path.join(os.path.dirname(os.path.abspath(journal.path)), name)
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def _private_write(path, text):
    tmp = f"{path}.{uuid.uuid4().hex}.tmp"
    fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def write_packet(journal, packet):
    """A private copy of the stored packet's exact text, for people and audits."""
    path = os.path.join(_state_dir(journal, "packets"), f"{packet['packet_id']}.md")
    _private_write(path, packet["text"])
    return path


def envelope(packet, note=None):
    """The turn's full text: the packet itself, then the ingress's note."""
    return packet["text"] + (f"\n{note}\n" if note else "")


def one_line(packet, note=None):
    """The same content for a transport that submits at the first newline: deterministic JSON."""
    body = {"canopy_work_context": packet["packet_id"], "digest": packet["digest"], "context": packet["text"]}
    if note:
        body["note"] = note
    return "Canopy work context, JSON-escaped; every instruction in it is in force: " + json.dumps(body, ensure_ascii=False, sort_keys=True)


class ClaudeSayTransport:
    host = "claude-say"
    prefix = "claude-say:"

    def __init__(self, path=None, timeout=30):
        self.path = path or os.environ.get("CANOPY_WORK_CLAUDE_SAY") or os.path.join(SCRIPTS, "claude-say")
        self.timeout = timeout

    def handles(self, target):
        return target.startswith(self.prefix) and len(target) > len(self.prefix)

    def payload(self, packet, note):
        return one_line(packet, note)

    def submit(self, target, payload, journal=None, receipt_id=None):
        who = target[len(self.prefix):]
        try:
            p = subprocess.run([self.path, who, payload], capture_output=True, text=True, timeout=self.timeout)
        except subprocess.TimeoutExpired:
            return "uncertain", "claude-say timed out after typing may have begun"
        except OSError as e:
            raise Failed(f"claude-say did not run: {e}") from None
        if p.returncode != 0:
            raise Failed((p.stderr or p.stdout or f"claude-say exited {p.returncode}").strip()[:500])
        return "uncertain", "typed into a tmux pane; claude-say has no checked submission acknowledgement"


class HeadlessClaudeTransport:
    """The owned host. A worker is registered first (`register`) with its working directory, its
    tool allowlist and the boot prompt its first turn starts with. Each turn is one `claude -p`
    process under an owned wrapper (`run_turn`) that records how it ended; one turn per worker
    at a time, decided under a per-worker lock so concurrent dispatchers can't both launch."""
    host = "claude-headless"
    prefix = "claude-headless:"

    def __init__(self, path=None, timeout=60, poll=0.05):
        self.path = path or os.environ.get("CANOPY_WORK_CLAUDE") or "claude"
        self.timeout = timeout
        self.poll = poll

    def handles(self, target):
        return target.startswith(self.prefix) and bool(SESSION.fullmatch(target[len(self.prefix):]))

    def payload(self, packet, note):
        return envelope(packet, note)

    @staticmethod
    def _conf_path(journal, session):
        return os.path.join(_state_dir(journal, "hosts"), f"{session}.json")

    @classmethod
    def _update(cls, journal, session, change):
        """Read-modify-write of a worker's config under its lock, so registration and a boot
        acknowledgement never overwrite each other."""
        with _locked(os.path.join(_state_dir(journal, "hosts"), f"{session}.lock")):
            conf = {**(cls.config(journal, session) or {"session": session, "booted": False}), **change}
            _private_write(cls._conf_path(journal, session), json.dumps(conf, sort_keys=True))
            return conf

    @classmethod
    def register(cls, journal, session, *, cwd, allowed_tools, boot_prompt=""):
        if not SESSION.fullmatch(session):
            raise wj.JournalError("a headless worker is named by a session uuid")
        cls._update(journal, session, {"cwd": cwd, "allowed_tools": allowed_tools, "boot_prompt": boot_prompt})
        return cls.prefix + session

    @classmethod
    def config(cls, journal, session):
        try:
            with open(cls._conf_path(journal, session)) as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    @classmethod
    def observe(cls, journal, worker, record=True):
        """The worker's turns as observed now: a running turn whose process is gone without an
        end record becomes lost (recorded unless `record` is False, for read-only callers); one
        whose identity can't be checked reads unknown. An open attempt record alone is never
        taken as a working process."""
        out = []
        for t in journal.turns(worker, running=True):
            alive = _alive(t["pid"], t["start_token"])
            if alive is False and record:
                journal.end_turn(t["receipt_id"], "lost", detail="the turn's process ended without recording how")
            out.append({**t, "observed": {True: "running", False: "lost", None: "unknown"}[alive]})
        return out

    @classmethod
    def busy(cls, journal, target):
        return any(t["observed"] in ("running", "unknown") for t in cls.observe(journal, target))

    @classmethod
    def worker_state(cls, journal, target):
        """none | running | unknown | ended (with the last turn's outcome), observed without writing."""
        last = journal.turns(target, limit=1)
        if not last:
            return {"state": "none"}
        live = cls.observe(journal, target, record=False)
        if any(t["observed"] == "running" for t in live):
            return {"state": "running", "pid": live[0]["pid"], "receipt_id": live[0]["receipt_id"]}
        if any(t["observed"] == "unknown" for t in live):
            return {"state": "unknown", "pid": live[0]["pid"], "receipt_id": live[0]["receipt_id"]}
        t = last[0]
        outcome = "lost" if t["outcome"] == "running" else t["outcome"]
        return {"state": "ended", "outcome": outcome, "receipt_id": t["receipt_id"], "ended_at": t["ended_at"],
                "exit_code": t["exit_code"], "detail": t["detail"]}

    def submit(self, target, payload, journal, receipt_id):
        session = target[len(self.prefix):]
        conf = self.config(journal, session)
        if conf is None:
            raise Failed(f"headless worker {session} is not registered")
        input_uuid = str(uuid.uuid4())
        booted = conf.get("booted") or journal.acknowledged_turn(target)
        text = payload if booted or not conf.get("boot_prompt") else conf["boot_prompt"] + "\n\n" + payload
        line = json.dumps({"type": "user", "uuid": input_uuid, "session_id": session, "parent_tool_use_id": None,
                           "message": {"role": "user", "content": [{"type": "text", "text": text}]}}) + "\n"
        d = _state_dir(journal, "hosts")
        log = os.path.join(d, f"{session}.{input_uuid}.out")
        err = os.path.join(d, f"{session}.{input_uuid}.err")
        receipt = journal.receipt(receipt_id)
        args = [self.path, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--replay-user-messages", "--permission-prompts", "none", "--allowedTools", conf["allowed_tools"],
                "--settings", compaction_settings(journal, receipt["attempt_id"]),
                *(["--resume", session] if booted else ["--session-id", session])]
        with _locked(os.path.join(d, f"{session}.lock")):
            for t in self.observe(journal, target):
                if t["observed"] == "running":
                    raise Failed(f"worker {session} is still running a turn (pid {t['pid']})")
                if t["observed"] == "unknown":
                    raise Failed(f"worker {session}'s last turn can't be identified; not starting another beside it")
            wrapper = [sys.executable, "-c", WRAPPER, SCRIPTS, journal.path, receipt_id, target, log, err, *args]
            try:
                p = subprocess.Popen(wrapper, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                     cwd=conf["cwd"], start_new_session=True)
            except OSError as e:
                raise Failed(f"the turn did not start: {e}") from None
            journal.record_turn(receipt_id, worker=target, pid=p.pid, start_token=_start_time(p.pid), input_uuid=input_uuid, log=log)
        try:
            p.stdin.write(line.encode("utf-8"))
            p.stdin.close()
        except BrokenPipeError:
            pass
        want = wj.digest(text)
        deadline = time.monotonic() + self.timeout
        while True:
            if _replayed(log, session, input_uuid, want):
                if not booted:
                    self._update(journal, session, {"booted": True})
                return "acknowledged", None
            code = p.poll()
            if code is not None and not _replayed(log, session, input_uuid, want):
                if code != 0:
                    raise Failed(f"claude exited {code} without accepting the turn: {_tail(err) or _tail(log)}")
                return "uncertain", "claude exited 0 without acknowledging this input"
            if time.monotonic() > deadline:
                return "uncertain", f"no acknowledgement of this input within {self.timeout}s; the turn may still run"
            time.sleep(self.poll)


def compaction_settings(journal, attempt_id):
    """Settings for one turn: after an automatic compaction the session reloads this attempt's
    canonical packet from the journal (hook stdout becomes context)."""
    cmd = " ".join(shlex.quote(x) for x in ("env", f"CANOPY_WORK_JOURNAL={os.path.abspath(journal.path)}", sys.executable,
                                            os.path.join(SCRIPTS, "canopy-work"), "boundary", "--attempt", attempt_id,
                                            "--boundary", "compaction"))
    return json.dumps({"hooks": {"SessionStart": [{"matcher": "compact", "hooks": [{"type": "command", "command": cmd}]}]}},
                      sort_keys=True)


WRAPPER = r"""
import json, subprocess, sys
scripts, journal, receipt, target, log, err, *args = sys.argv[1:]
sys.path.insert(0, scripts)
from srv import workdelivery, workjournal as wj
with open(log, "ab") as out, open(err, "ab") as e:
    code = subprocess.run(args, stdin=sys.stdin, stdout=out, stderr=e).returncode
result = None
for line in open(log, encoding="utf-8", errors="replace"):
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    if isinstance(ev, dict) and ev.get("type") == "result":
        result = ev
ok = code == 0 and result is not None and not result.get("is_error")
detail = None if ok else (f"exit {code}" + (f"; {result.get('subtype')}: {str(result.get('result') or '')[:300]}" if result else "; no result"))
j = wj.Journal(journal)
j.end_turn(receipt, "succeeded" if ok else "failed", exit_code=code, detail=detail)
try:
    workdelivery.dispatch(j, [workdelivery.HeadlessClaudeTransport(path=args[0])], target=target)
except Exception as e:
    j.end_turn(receipt, "failed", detail=f"next dispatch failed: {e}")
sys.exit(code)
"""


class _locked:
    def __init__(self, path):
        self.path = path

    def __enter__(self):
        self.fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)

    def __exit__(self, *exc):
        os.close(self.fd)


def _replayed(log, session, input_uuid, want):
    """Whether the host's stdout re-emitted exactly this input: a user event carrying our uuid
    (or none, with the session) whose text has the digest we sent."""
    try:
        with open(log, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        return False
    for line in lines:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if not isinstance(ev, dict) or ev.get("type") != "user":
            continue
        if ev.get("uuid") not in (None, input_uuid) or ev.get("session_id") not in (None, session):
            continue
        content = (ev.get("message") or {}).get("content")
        text = content if isinstance(content, str) else "".join(
            b.get("text", "") for b in content or [] if isinstance(b, dict) and b.get("type") == "text")
        if wj.digest(text) == want:
            return True
    return False


def _tail(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return " ".join(f.read()[-400:].split())
    except OSError:
        return ""


def _start_time(pid):
    try:
        out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True, timeout=5).stdout.strip()
        return out or None
    except (OSError, subprocess.TimeoutExpired):
        return None


def _alive(pid, token):
    """True only for a live process whose start time matches the recorded token; False when it
    is gone or the pid now names another process; None when there's no identity to check or the
    live process can't be inspected."""
    if not pid:
        return None
    try:
        os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        pass
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    if not token:
        return None
    now = _start_time(pid)
    if now is None:
        return None
    return now == token


def transports():
    return [HeadlessClaudeTransport(), ClaudeSayTransport()]


def dispatch(journal, transports, *, owner=None, limit=10, fault=None, target=None):
    """Delivers due outbox rows once (optionally only one target's). Returns one outcome dict per
    leased row. `fault(stage)` is a test hook naming each durable step. The owned host's wrapper
    calls this for its worker when a turn ends: the next safe boundary for queued direction."""
    owner = owner or f"dispatch:{os.getpid()}:{uuid.uuid4().hex[:8]}"
    fault = fault or (lambda stage: None)
    return [_deliver_row(journal, transports, row, fault) for row in journal.lease(owner, limit=limit, target=target)]


def _deliver_row(journal, transports, row, fault):
    ob, token, target = row["outbox_id"], row["lease_token"], row["target"]
    res = {"outbox_id": ob, "message_id": row["message_id"], "target": target}
    journal.abandon_open_receipts(ob, "the previous dispatcher stopped mid-hand-off")
    earlier = journal.handoffs(ob)
    if "acknowledged" in earlier:
        journal.settle(ob, token, "delivered", error="an earlier hand-off was acknowledged")
        return {**res, "outcome": "delivered", "detail": "reconciled an acknowledged hand-off; nothing sent"}
    if "uncertain" in earlier:
        journal.settle(ob, token, "uncertain", error="an earlier hand-off may have reached the worker; requeue to send again")
        return {**res, "outcome": "uncertain", "detail": "reconciled an uncertain hand-off; nothing sent"}
    transport = next((t for t in transports if t.handles(target)), None)
    if transport is None:
        journal.settle(ob, token, "failed", error=f"no supported transport for {target}", max_attempts=1)
        return {**res, "outcome": "abandoned", "detail": "unsupported host"}
    if getattr(transport, "busy", None) and transport.busy(journal, target):
        journal.settle(ob, token, "deferred", error="the worker is in a turn; this goes when it ends", retry_in=5)
        return {**res, "outcome": "deferred", "detail": "worker busy"}
    works = journal.message_works(row["message_id"])
    if not works:
        journal.settle(ob, token, "failed", error="unassigned: a person must decide which work it belongs to", max_attempts=1)
        return {**res, "outcome": "abandoned", "detail": "unassigned"}
    attempt = journal.attempt_for(target, works)
    boundary = "turn"
    try:
        if attempt is None:
            attempt = journal.begin_attempt(works, worker=target, host=transport.host, managed=True)["attempt_id"]
            boundary = "start"
        for tries in range(3):
            packet = journal.prepare(attempt)
            try:
                receipt = journal.open_receipt(packet["packet_id"], boundary=boundary, outbox_id=ob)
                break
            except wj.Conflict:
                if tries == 2:
                    raise
        write_packet(journal, packet)
        payload = transport.payload(packet, row.get("note"))
        journal.record_payload(receipt, transport.host, payload)
    except (wj.JournalError, OSError) as e:
        journal.settle(ob, token, "failed", error=f"could not prepare context: {e}")
        return {**res, "outcome": "failed", "detail": str(e)}
    res.update(attempt_id=attempt, packet_id=packet["packet_id"], receipt_id=receipt, boundary=boundary)
    fault("opened")
    try:
        state, detail = transport.submit(target, payload, journal, receipt)
    except Failed as e:
        journal.settle_receipt(receipt, "failed", str(e))
        if "still running" in str(e):
            journal.settle(ob, token, "deferred", error=str(e), retry_in=5)
            return {**res, "outcome": "deferred", "detail": str(e)}
        journal.settle(ob, token, "failed", error=str(e))
        return {**res, "outcome": "failed", "detail": str(e)}
    except Exception as e:  # noqa: BLE001 — anything after the hand-off began leaves it unknown
        journal.settle_receipt(receipt, "uncertain", f"transport raised {type(e).__name__}: {e}")
        journal.settle(ob, token, "uncertain", error=str(e))
        return {**res, "outcome": "uncertain", "detail": str(e)}
    fault("submitted")
    journal.settle_receipt(receipt, state, detail)
    fault("receipt-settled")
    journal.settle(ob, token, "delivered" if state == "acknowledged" else "uncertain", error=detail)
    return {**res, "outcome": "delivered" if state == "acknowledged" else "uncertain", "detail": detail}


def deliver_boundary(journal, attempt_id, boundary, *, emit):
    """A start, resume or compaction boundary in a host that takes context by output (a session
    hook's stdout): prepares the packet, records the hand-off and calls `emit(text)`. The host
    does not confirm what it did with the output, so the receipt is uncertain, and results cited
    against it stay unverified until a confirmed delivery follows."""
    packet = journal.prepare(attempt_id)
    receipt = journal.open_receipt(packet["packet_id"], boundary=boundary)
    journal.record_payload(receipt, "output", packet["text"])
    try:
        emit(packet["text"])
    except Exception as e:  # noqa: BLE001
        journal.settle_receipt(receipt, "failed", f"could not emit: {e}")
        raise
    journal.settle_receipt(receipt, "uncertain", "emitted to the host; submission not confirmed")
    return {"packet_id": packet["packet_id"], "receipt_id": receipt}

