#!/usr/bin/env python3
"""srv/telemetry.py's summary over folded events: the never-used list and the v1 pairs read the
app that posted the registry, so a native command with uses is not reported as never used."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from srv import telemetry  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


now = time.time()
actor = next(a for a in telemetry.HUMAN_ACTORS if a)
cache = {"v": telemetry.ROLLUP_V, "ino": None, "off": 0, "days": {}, "registry": None}
events = [
    {"schema": 2, "app": "native", "type": "registry", "ts": now - 60,
     "commands": [{"id": "cursor.down"}, {"id": "cursor.halfdown"}, {"id": "nav.wiki", "v1": ["key:w"]}]},
    {"schema": 2, "app": "native", "type": "cmd", "id": "cursor.halfdown", "ts": now - 30, "actor": actor,
     "budget": "local", "via": "key", "outcome": "ok", "feedbackMs": 8},
    {"schema": 2, "app": "native", "type": "cmd", "id": "nav.wiki", "ts": now - 30, "actor": actor,
     "budget": "local", "via": "key", "outcome": "ok", "feedbackMs": 9},
    {"schema": 2, "app": "v2", "type": "cmd", "id": "cursor.down", "ts": now - 30, "actor": actor,
     "budget": "local", "via": "key", "outcome": "ok", "feedbackMs": 5},
]
for e in events:
    cache["registry"] = telemetry.fold(cache["days"], cache["registry"], e)
s = telemetry.summarize(cache, days=30, now=now)

check("a native command with uses is not never-used", "cursor.halfdown" not in s["neverUsed"], s["neverUsed"])
check("a registered command only v2 used is never-used for native", "cursor.down" in s["neverUsed"], s["neverUsed"])
pair = next((p for p in s["pairs"] if p["id"] == "nav.wiki"), None)
check("a v1 pair reads the registry app's row", pair is not None and (pair["v2"] or {}).get("app") == "native", pair)

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
