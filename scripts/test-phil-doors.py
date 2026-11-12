#!/usr/bin/env python3
"""The doors only Phil's click may open refuse everyone else, in the handler itself: the push to
origin, the force-replace, the waiver, and the kills of processes another session may own. A
request claiming "browser" from a process that isn't Show is refused too — the claim alone is a
header any curl can send."""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


class _State:
    @staticmethod
    def poke():
        pass


sys.modules["srv.state"] = _State
from srv import actor, preview, push, queue, verdicts  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


class Req:
    def __init__(self, who):
        self._actor = who
        self.client_address = ("127.0.0.1", 1)
        self.status, self.body = None, None

    def _send(self, status, body):
        self.status, self.body = status, json.loads(body)


# the peer is this test process, which is not Show — so even a "browser" claim is not Phil
actor._peer_pid = lambda port: os.getpid()

DOORS = {
    "push to origin": push.push_origin,
    "force-replace origin": push.force_origin,
    "waive the gates": verdicts.waive,
    "kill a queue process": queue.kill,
    "kill a preview": preview.kill,
    "reap previews": preview.reap,
    "swap a preview": preview.swap,
}
RAW = json.dumps({"branch": "__probe__", "pid": 1, "dir": "/nonexistent", "port": 1})

for who in ("claude", "cli", "browser"):
    for name, door in DOORS.items():
        r = Req(who)
        door(r, RAW)
        check(f"{name} refuses a {who} request", r.status == 403 and r.body.get("ok") is False, (r.status, r.body))

sys.exit(1 if failures else 0)
