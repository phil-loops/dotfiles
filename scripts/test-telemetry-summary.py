#!/usr/bin/env python3
"""srv/telemetry.py's summary over folded events: the never-used list and the v1 pairs read the
app that posted the registry, so a native command with uses is not reported as never used."""
import json
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
     "commands": [{"id": "cursor.down"}, {"id": "cursor.halfdown"}, {"id": "review.down"}, {"id": "nav.tutor", "v1": ["key:t"]}]},
    {"schema": 2, "app": "native", "type": "cmd", "id": "cursor.halfdown", "ts": now - 30, "actor": actor,
     "budget": "local", "via": "key", "outcome": "ok", "feedbackMs": 8},
    {"schema": 2, "app": "native", "type": "cmd", "id": "nav.tutor", "ts": now - 30, "actor": actor,
     "budget": "local", "via": "key", "outcome": "ok", "feedbackMs": 9},
    {"schema": 2, "app": "v2", "type": "cmd", "id": "cursor.down", "ts": now - 30, "actor": actor,
     "budget": "local", "via": "key", "outcome": "ok", "feedbackMs": 5},
]
events += [
    {"schema": 2, "app": "native", "type": "cmd", "id": "review.down", "ts": now - 20, "actor": actor, "budget": "local",
     "via": "key", "outcome": "ok", "feedbackMs": 800, "surface": "review", "sinceNavMs": 300},
    {"schema": 2, "app": "native", "type": "cmd", "id": "review.down", "ts": now - 19, "actor": actor, "budget": "local",
     "via": "key", "outcome": "ok", "feedbackMs": 10, "surface": "review", "sinceNavMs": 9000},
    {"schema": 2, "app": "native", "type": "cmd", "id": "review.down", "ts": now - 18, "actor": actor, "budget": "local",
     "via": "key", "outcome": "ok", "feedbackMs": 12, "surface": "forest", "sinceNavMs": 9000},
]
events += [
    {"schema": 2, "app": "native", "type": "cmd", "id": "history.next", "ts": now - 10, "at": (now - 10) * 1000, "actor": actor, "pl": "p1", "budget": "local", "via": "key", "outcome": "ok", "feedbackMs": 5},
    {"schema": 2, "app": "native", "type": "cmd", "id": "history.prev", "ts": now - 9.5, "at": (now - 9.5) * 1000, "actor": actor, "pl": "p1", "budget": "local", "via": "key", "outcome": "ok", "feedbackMs": 5},
    {"schema": 2, "app": "native", "type": "cmd", "id": "words.save", "ts": now - 8, "actor": actor, "pl": "p1", "budget": "git-write", "via": "key", "outcome": "ok", "feedbackMs": 5},
    {"schema": 2, "app": "native", "type": "cmd", "id": "undo", "ts": now - 7, "actor": actor, "pl": "p1", "budget": "local", "via": "key", "outcome": "ok", "feedbackMs": 5},
    {"schema": 2, "app": "native", "type": "cmd", "id": "history.prev", "ts": now - 6, "actor": actor, "pl": "p2", "budget": "local", "via": "key", "outcome": "refused", "err": "already at the top", "feedbackMs": 5},
]
for e in events:
    telemetry.fold(cache, e)
s = telemetry.summarize(cache, days=30, now=now)

check("a native command with uses is not never-used", "cursor.halfdown" not in s["neverUsed"], s["neverUsed"])
check("a registered command only v2 used is never-used for native", "cursor.down" in s["neverUsed"], s["neverUsed"])
pair = next((p for p in s["pairs"] if p["id"] == "nav.tutor"), None)
check("a v1 pair reads the registry app's row", pair is not None and (pair["v2"] or {}).get("app") == "native", pair)

down = next(c for c in s["commands"] if c["app"] == "native" and c["id"] == "review.down")
check("keys within 1.5 s of a page open are the cold split", down["cold"] == {"n": 1, "p50": 800, "p95": 800}, down["cold"])
check("…the rest the warm split", down["warm"]["n"] == 2 and down["warm"]["p95"] == 12, down["warm"])
check("…and each surface has its own stats, busiest first", list(down["surfaces"]) == ["review", "forest"] and down["surfaces"]["review"]["n"] == 2, down["surfaces"])

sess = s["sessions"]["native"]
# a server restart between two keys of one launch: the cache is saved, the module starts fresh
import importlib  # noqa: E402
cut = next(i for i, e in enumerate(events) if e.get("id") == "undo")
again = {"days": {}, "registry": None}
for e in events[:cut]:
    telemetry.fold(again, e)
again = json.loads(json.dumps(again))
importlib.reload(telemetry)
for e in events[cut:]:
    telemetry.fold(again, e)
resumed = telemetry.summarize(again, days=30, now=now)["sessions"]
check("a restart mid-launch still pairs the undo with the key before it", resumed == s["sessions"], resumed)
check("sessions count launches, refusals, an undo right after a key, and a reversed motion",
      sess["launches"] == 2 and sess["refused"] == 1 and sess["undoSoon"] == 1 and sess["reversed"] == 1, sess)


# 2026-11-18: one 3 s batch shares one receipt second, so "reversed within 1 s" counted any opposite
# pair in a batch — and a move refused at the end followed by its opposite counted as an overshoot
def launch(pl, moves):
    c = {"days": {}, "registry": None}
    for i, (cid, at, outcome) in enumerate(moves):
        e = {"schema": 2, "app": "native", "type": "cmd", "id": cid, "ts": int(now), "actor": actor, "pl": pl,
             "budget": "local", "via": "key", "outcome": outcome, "feedbackMs": 5}
        if at is not None:
            e["at"] = (now + at) * 1000
        telemetry.fold(c, e)
    return telemetry.summarize(c, days=30, now=now)["sessions"]["native"]["reversed"]


check("one receipt second, presses 2.5 s apart: not a reversal",
      launch("q1", [("review.down", 0, "ok"), ("review.up", 2.5, "ok")]) == 0)
check("presses 0.3 s apart: a reversal", launch("q2", [("review.down", 0, "ok"), ("review.up", 0.3, "ok")]) == 1)
check("a move refused at the end, then back: a bounce, not a reversal",
      launch("q3", [("review.down", 0, "refused"), ("review.up", 0.2, "ok")]) == 0)
check("no press times: the gap is unknown, so it isn't counted",
      launch("q4", [("review.down", None, "ok"), ("review.up", None, "ok")]) == 0)

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
