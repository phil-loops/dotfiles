#!/usr/bin/env python3
"""srv/push.py's run_progress — a gates run as the store's `gaterun` entity carries it: the
journal's events, `started` instead of a ticking elapsed, the result once there is one, `dead`
for a run that died without one — and no side effects (no verdict harvest). Frozen journals."""
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


class _State:
    @staticmethod
    def poke():
        pass


sys.modules["srv.state"] = _State
from srv import push  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


class Run:
    def __init__(self, events, alive):
        self.dir = tempfile.mkdtemp(prefix="gaterun-")
        self.meta = {"journal": "j.jsonl", "tree": "t1", "branch": "b"}
        self.started = 1000.25
        self._alive = alive
        with open(self.path("j.jsonl"), "w") as f:
            f.write("".join(json.dumps(e) + "\n" for e in events))

    def path(self, name):
        return os.path.join(self.dir, name)

    def alive(self):
        return self._alive


harvested = []
push._harvest_green = lambda *a, **k: harvested.append(a) or True
plan = {"event": "plan", "gates": ["env", "tests"]}
live = push.run_progress(Run([plan, {"event": "start", "gate": "env", "ts": 1001}], alive=True))
check("a live run carries its events, tree and start, not a ticking elapsed",
      live["running"] and live["tree"] == "t1" and live["started"] == 1000.25 and "elapsed" not in live and len(live["events"]) == 2, live)
check("a live run is neither dead nor finished", "dead" not in live and "result" not in live)
done = push.run_progress(Run([plan, {"event": "result", "ok": True, "gates": [{"name": "env", "ok": True}]}], alive=False))
check("a finished run carries its result", done.get("result", {}).get("ok") is True and not done["running"])
dead = push.run_progress(Run([plan], alive=False))
check("a run that died without a result is dead", dead.get("dead") is True)
check("no verdict is harvested by building the entity", harvested == [])
check("the entity is plain JSON", json.loads(json.dumps(done)) == done)
print("all passed" if not failures else f"{failures} failed")
sys.exit(1 if failures else 0)
