#!/usr/bin/env python3
"""Send an attributed external-agent reply to an explicitly allowed Codex GUI chat.

Uses this desktop build's PRIVATE local coordination IPC, not a public API.
The desktop build is pinned in the adjacent configuration; updates fail closed.
No draft edits, queue replacement, turn interruption, or fallback server is used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import socket
import sqlite3
import stat
import struct
import sys
import time
import uuid

MAX_FRAME = 32 * 1024 * 1024
MAX_BODY = 256 * 1024
METHODS = {"initialize": 0, "thread-owner-discovery": 1,
           "thread-follower-read-model-settings": 1, "thread-follower-start-turn": 2}


class BridgeError(Exception):
    pass


class DeliveryUnknown(BridgeError):
    pass


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def private_socket(path):
    metadata, parent = path.lstat(), path.parent.lstat()
    if (not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != os.getuid()
            or metadata.st_mode & 0o077 or not stat.S_ISDIR(parent.st_mode)
            or parent.st_uid != os.getuid() or parent.st_mode & 0o022):
        raise BridgeError("Refusing an IPC socket outside a protected current-user directory")


class DesktopIpc:
    def __init__(self, path, timeout=20):
        private_socket(path)
        self.timeout = timeout
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(timeout)
        try:
            self.sock.connect(str(path))
            self.client_id = "uninitialized"
            hello = self.call("initialize", {"clientType": "codex-say-external-agent"})
            self.client_id = hello["result"]["clientId"]
        except Exception:
            self.sock.close()
            raise

    def close(self):
        self.sock.close()

    def _exact(self, count, deadline):
        data = bytearray()
        while len(data) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Desktop IPC response timed out")
            self.sock.settimeout(remaining)
            chunk = self.sock.recv(count - len(data))
            if not chunk:
                raise ConnectionError("Desktop IPC disconnected")
            data.extend(chunk)
        return bytes(data)

    def call(self, method, params, owner=None):
        if method not in METHODS:
            raise BridgeError("Method is not allowed by this adapter")
        request_id = str(uuid.uuid4())
        envelope = {"type": "request", "requestId": request_id,
                    "sourceClientId": self.client_id, "version": METHODS[method],
                    "method": method, "params": params,
                    "timeoutMs": int(self.timeout * 1000)}
        if owner is not None:
            envelope["targetClientId"] = owner
        data = canonical(envelope).encode()
        if len(data) > MAX_FRAME:
            raise BridgeError("Request exceeds the frame limit")
        self.sock.settimeout(self.timeout)
        self.sock.sendall(struct.pack("<I", len(data)) + data)
        deadline = time.monotonic() + self.timeout
        while True:
            size = struct.unpack("<I", self._exact(4, deadline))[0]
            if not 0 < size <= MAX_FRAME:
                raise BridgeError("Invalid IPC frame length")
            message = json.loads(self._exact(size, deadline))
            # The router also emits broadcasts. Do not retain or act on other chats.
            if message.get("type") != "response" or message.get("requestId") != request_id:
                continue
            if message.get("resultType") != "success":
                raise BridgeError("Desktop IPC rejected the request: " + str(message.get("error")))
            return message

    def prepare(self, target):
        owner = self.call("thread-owner-discovery", {"hostId": "local", "conversationId": target})
        owner_id = owner.get("handledByClientId")
        if not owner_id:
            raise BridgeError("No live GUI owner; open the allowed chat in Codex")
        settings = self.call("thread-follower-read-model-settings", {"conversationId": target}, owner_id)
        if not settings.get("result", {}).get("settings"):
            raise BridgeError("The GUI owner has no loaded settings for this chat")
        return owner_id

    def deliver(self, target, request, owner):
        # The owner preserves its own settings. The server handles active/idle
        # tool-output admission atomically; no read/start race or interrupt is used.
        return self.call("thread-follower-start-turn", {
            "conversationId": target, "turnStart": {"request": request,
            "context": {"inheritThreadSettings": True}}}, owner)


class Outbox:
    def __init__(self, state_dir):
        state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        if state_dir.is_symlink() or state_dir.stat().st_uid != os.getuid():
            raise BridgeError("State directory must be owned by the current user")
        state_dir.chmod(0o700)
        path = state_dir / "outbox.sqlite3"
        if path.is_symlink():
            raise BridgeError("Refusing a symlinked ledger")
        self.db = sqlite3.connect(path, timeout=10)
        path.chmod(0o600)
        self.db.execute("""CREATE TABLE IF NOT EXISTS messages (
            host TEXT, target TEXT, sender TEXT, source_session TEXT, message_id TEXT,
            payload_hash TEXT NOT NULL, state TEXT NOT NULL, receipt TEXT,
            created_at REAL NOT NULL, updated_at REAL NOT NULL,
            PRIMARY KEY(host,target,sender,source_session,message_id))""")
        self.db.commit()

    def close(self):
        self.db.close()

    def reserve(self, key, digest):
        self.db.execute("BEGIN IMMEDIATE")
        row = self.db.execute("SELECT payload_hash,state,receipt FROM messages WHERE host=? AND target=? AND sender=? AND source_session=? AND message_id=?", key).fetchone()
        if row:
            if row[0] != digest:
                self.db.rollback()
                raise BridgeError("Message ID already exists with different content or attribution")
            if row[1] == "not_dispatched":
                self.db.execute("UPDATE messages SET state='dispatching',receipt=NULL,updated_at=? WHERE host=? AND target=? AND sender=? AND source_session=? AND message_id=?", (time.time(), *key))
                self.db.commit()
                return None
            self.db.rollback()
            return {"state": row[1], "deduplicated": True,
                    "receipt": json.loads(row[2]) if row[2] else None}
        now = time.time()
        self.db.execute("INSERT INTO messages VALUES (?,?,?,?,?,?,?,NULL,?,?)", (*key, digest, "dispatching", now, now))
        self.db.commit()
        return None

    def finish(self, key, state, receipt):
        self.db.execute("UPDATE messages SET state=?,receipt=?,updated_at=? WHERE host=? AND target=? AND sender=? AND source_session=? AND message_id=?",
                        (state, canonical(receipt), time.time(), *key))
        self.db.commit()


def load_config(path):
    metadata = path.lstat()
    if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
            or metadata.st_mode & 0o022):
        raise BridgeError("Configuration must be an unshared regular file owned by the current user")
    config = json.loads(path.read_text())
    if config.get("schema_version") != 1:
        raise BridgeError("Unsupported configuration schema")
    if not isinstance(config.get("targets"), dict) or not isinstance(config.get("senders"), dict):
        raise BridgeError("Configuration requires explicit targets and senders")
    return config


def check_build(config):
    app = config["desktop"]
    with (Path(app["app_path"]) / "Contents/Info.plist").open("rb") as source:
        installed = plistlib.load(source)
    if (installed.get("CFBundleVersion") != app["build"]
            or installed.get("CFBundleShortVersionString") != app["version"]):
        raise BridgeError("Desktop version changed; validate the private IPC adapter before updating the build pin")


def resolve_target(config, value):
    entries = [(alias, item) for alias, item in config["targets"].items()
               if alias == value or item.get("thread_id") == value]
    if len(entries) != 1:
        raise BridgeError("Target is not an unambiguous explicitly allowed alias or exact UUID")
    alias, target = entries[0]
    if target.get("host_id") != "local":
        raise BridgeError("This adapter supports only local Codex chats")
    try:
        uuid.UUID(target["thread_id"])
    except (ValueError, KeyError):
        raise BridgeError("Allowed target is missing a valid thread UUID")
    return alias, target


def make_request(target, sender_id, sender, source_session, message_id, body, fixture):
    payload = {"kind": "external_agent_reply", "sender_id": sender_id,
               "sender": sender["label"], "source_session": source_session,
               "message_id": message_id, "synthetic_test_fixture": fixture, "body": body}
    digest = hashlib.sha256(canonical(payload).encode()).hexdigest()
    label = sender["label"] + (" (synthetic test fixture)" if fixture else "")
    output = (f"External agent reply — {label}\nMessage ID: {message_id}\n"
              f"Source session: {source_session}\n\n" + canonical(payload))
    client_id = str(uuid.uuid5(uuid.NAMESPACE_URL, canonical([target, sender_id, source_session, message_id])))
    request = {"threadId": target, "input": [], "clientUserMessageId": client_id,
               "toolOutput": {"namespace": "external_agents", "name": "claude_code_reply", "output": output}}
    return request, digest


def send(config, config_dir, target_value, sender_id, source_session, message_id, body, fixture,
         dry_run=False, ipc_factory=DesktopIpc):
    alias, target = resolve_target(config, target_value)
    sender = config["senders"].get(sender_id)
    if not sender or not sender.get("label"):
        raise BridgeError("Sender is not explicitly configured")
    if not source_session.strip() or not message_id.strip() or not body.strip():
        raise BridgeError("Source session, message ID, and body must be nonempty")
    if len(body.encode()) > MAX_BODY:
        raise BridgeError("Message exceeds 256 KiB")
    if target.get("fixture_only") and not fixture:
        raise BridgeError("This disposable target accepts only explicitly labeled test fixtures")
    if fixture and target.get("allow_fixtures") is False:
        raise BridgeError("Test fixtures are forbidden for this target; use the disposable chat")
    request, digest = make_request(target["thread_id"], sender_id, sender, source_session, message_id, body, fixture)
    if dry_run:
        return {"dry_run": True, "target": alias, "request": request}
    check_build(config)
    state = Path(config["state_dir"]).expanduser()
    if not state.is_absolute():
        state = config_dir / state
    ledger = Outbox(state)
    key = ("local", target["thread_id"], sender_id, source_session, message_id)
    ipc = None
    try:
        # Accepted or uncertain prior attempts never resend. A failed read-only
        # preflight is known not to have dispatched and may safely be retried.
        # Reserve first, then a failed preflight is recorded as not_dispatched.
        existing = ledger.reserve(key, digest)
        if existing:
            return {"target": alias, "thread_id": target["thread_id"], "message_id": message_id, **existing}
        try:
            ipc = ipc_factory(Path(config["ipc_socket"]).expanduser())
            owner = ipc.prepare(target["thread_id"])
        except Exception as error:
            ledger.finish(key, "not_dispatched", {"error": str(error)})
            raise BridgeError("No message was dispatched: " + str(error)) from error
        try:
            raw = ipc.deliver(target["thread_id"], request, owner)
            result = raw["result"]["result"]
            turn_id = result["turn"]["id"]
            receipt = {"turn_id": turn_id, "owner_client_id": owner,
                       "client_message_id": request["clientUserMessageId"], "payload_sha256": digest}
            ledger.finish(key, "accepted", receipt)
            return {"state": "accepted", "deduplicated": False, "target": alias,
                    "thread_id": target["thread_id"], "message_id": message_id, "receipt": receipt}
        except Exception as error:
            ledger.finish(key, "unknown", {"error": str(error)})
            raise DeliveryUnknown("Delivery is unknown; do not resend with a new ID. " + str(error)) from error
    finally:
        if ipc:
            ipc.close()
        ledger.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", nargs="?", help="Configured alias or exact allowed chat UUID")
    parser.add_argument("--config", type=Path, default=Path(__file__).with_name("codex-say.json"))
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--sender", default="claude-code")
    parser.add_argument("--source-session", help="Real producer session ID, or explicit fixture session")
    parser.add_argument("--id", dest="message_id", help="Stable message ID; defaults to a content hash for safe retries")
    parser.add_argument("--fixture", action="store_true", help="Label synthetic test data explicitly")
    parser.add_argument("--dry-run", action="store_true")
    content = parser.add_mutually_exclusive_group()
    content.add_argument("--message")
    content.add_argument("--message-file", type=Path, help="UTF-8 body file, or - for stdin")
    args = parser.parse_args()
    try:
        config = load_config(args.config)
        if args.list:
            print(json.dumps(config["targets"], indent=2))
            return 0
        if not args.target or not args.source_session:
            parser.error("target and --source-session are required")
        if args.message is not None:
            body = args.message
        elif args.message_file is not None:
            if str(args.message_file) == "-":
                body = sys.stdin.buffer.read(MAX_BODY + 1).decode("utf-8")
            else:
                with args.message_file.open("rb") as source:
                    body = source.read(MAX_BODY + 1).decode("utf-8")
        else:
            parser.error("--message or --message-file is required")
        message_id = args.message_id or "sha256-" + hashlib.sha256(body.encode()).hexdigest()
        result = send(config, args.config.absolute().parent, args.target, args.sender,
                      args.source_session, message_id, body, args.fixture, args.dry_run)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0 if result.get("state") in (None, "accepted") else 3
    except (BridgeError, OSError, ValueError, KeyError) as error:
        print(str(error), file=sys.stderr)
        return 3 if isinstance(error, DeliveryUnknown) else 2


if __name__ == "__main__":
    sys.exit(main())
