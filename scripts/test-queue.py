#!/usr/bin/env python3
"""srv/queue.py's composer: holders and waiters with their process trees, a gate run matched to its
ticket and named by its step, an idle holder flagged, heavy work outside the queue flagged."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


class _State:
    @staticmethod
    def poke():
        pass


sys.modules["srv.state"] = _State
from srv import queue  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


NOW = 1_000_000.0
ns = lambda secs_ago: int((NOW - secs_ago) * 1e9)  # noqa: E731
ht = {"slots": 1, "configured": 2, "mem": 24,
      "held": [{"id": "t1", "pid": 100, "cls": "eval", "batch": True, "created": ns(19 * 3600), "cmd": ["python3", "eval.py"], "cwd": "/w/eval"},
               {"id": "t2", "pid": 200, "cls": "gates", "batch": False, "created": ns(300), "cmd": ["stack-gates", "--branch", "feat"], "cwd": "/w/feat"}],
      "waiting": [{"id": "t3", "pid": 300, "cls": "gates", "batch": False, "created": ns(60), "cmd": ["stack-gates", "--branch", "other"], "cwd": "/w/other"}]}
procs = [
    {"pid": 100, "ppid": 1, "cpu": 0.0, "rssMb": 300, "age": 19 * 3600, "command": "python3 eval.py"},
    {"pid": 101, "ppid": 100, "cpu": 0.1, "rssMb": 50, "age": 19 * 3600, "command": "node something"},
    {"pid": 190, "ppid": 1, "cpu": 1.0, "rssMb": 20, "age": 310, "command": "python3 /s/stack-gates --branch feat"},   # the run's launcher
    {"pid": 200, "ppid": 190, "cpu": 95.0, "rssMb": 2500, "age": 290, "command": "node /x/tsc --noEmit"},             # the ticket (holds a slot)
    {"pid": 300, "ppid": 1, "cpu": 0.0, "rssMb": 5, "age": 60, "command": "python3 /s/heavy-turn -- stack-gates"},
    {"pid": 400, "ppid": 1, "cpu": 300.0, "rssMb": 1800, "age": 120, "command": "/u/bin/seed-gen --sync /w/warm"},   # outside the queue
    {"pid": 500, "ppid": 1, "cpu": 0.0, "rssMb": 10, "age": 5, "command": "/bin/zsh -l"},
    {"pid": 600, "ppid": 1, "cpu": 0.0, "rssMb": 3, "age": 50, "command": "/bin/zsh -c 'npx tsc --noEmit'"},   # a shell naming the tool, not the tool
]
gates = [{"branch": "feat", "pid": 190, "started": NOW - 310, "step": "typecheck"},
         {"branch": "other", "pid": 300, "started": NOW - 60, "step": "1st in line"}]
q = queue.compose(ht, procs, gates, now=NOW)

check("the floor is named when memory cut the budget", q["floor"] == "memory 24% headroom cut the budget to 1", q["floor"])
h = {x["id"]: x for x in q["holders"]}
check("a holder's cpu and memory sum over its tree", h["t1"]["cpu"] == 0.1 and h["t1"]["rssMb"] == 350, h["t1"])
check("a holder idle past 15 minutes is flagged", h["t1"]["idle"] and not h["t2"]["idle"], (h["t1"]["idle"], h["t2"]["idle"]))
check("a gates ticket names its run's branch and step", h["t2"]["gate"] == {"branch": "feat", "step": "typecheck"}, h["t2"]["gate"])
w = q["waiters"][0]
check("a waiter knows its run too", w["gate"] == {"branch": "other", "step": "1st in line"} and w["age"] == 60, w)
check("heavy work outside the queue is listed, the queued tree is not", [o["pid"] for o in q["outside"]] == [400], q["outside"])
check("the warnings say both", len(q["warnings"]) == 2 and "holding, not working" in q["warnings"][0] and "outside the queue" in q["warnings"][1], q["warnings"])

check("a queued run says its place", queue.gate_step([], {"position": 2}) == "2nd in line")
check("a run in setup says the step", queue.gate_step([{"event": "setup", "step": "env"}]) == "env (seed-gen)")
check("a run on a gate says the gate", queue.gate_step([{"event": "setup", "step": "env"}, {"event": "start", "gate": "typecheck"}]) == "typecheck")
check("between gates it says the setup word", queue.gate_step([{"event": "start", "gate": "env"}, {"event": "done", "gate": "env"}]) == "starting")
check("elapsed parses", queue._etime("01:34:20") == 5660 and queue._etime("16-15:35:33") == 16 * 86400 + 15 * 3600 + 35 * 60 + 33 and queue._etime("05:07") == 307)

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
