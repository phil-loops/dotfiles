#!/usr/bin/env python3
"""srv/preview.py in the sandbox: the list is empty and every write refuses in words, so a
sandbox never lists or touches the machine's real dev servers."""
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
os.environ["STACK_REVIEW_SANDBOX"] = "1"
from srv import preview  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


class Req:
    def __init__(self):
        self.status, self.body = None, None

    def _send(self, status, body):
        self.status, self.body = status, json.loads(body)


r = Req(); preview.previews(r)
check("the sandbox lists no previews", r.status == 200 and r.body == {"ok": True, "previews": [], "substrate": None, "sandbox": True}, r.body)
for name in ("start", "start_integration", "start_main", "restart", "swap", "kill", "reap", "stack_up"):
    r = Req(); getattr(preview, name)(r, "{}")
    check(f"{name} refuses in the sandbox", r.status == 200 and r.body == {"ok": False, "err": preview.SANDBOX_REFUSAL}, r.body)

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
