# srv/queue.py — GET /queue: who holds the heavy-turn slots, who waits, what each gate run waits
# on, and heavy work running outside the queue — in one read-only answer, so a gates run that
# sits for an hour is diagnosed from the Machine page instead of ps archaeology (2026-11-04: an
# 18-hour eval held a slot at 0% CPU, the memory floor had cut the budget to one, and two review
# warm-ups ran seed-gen outside the queue; the branch page said 'gates starting · 4m 50s').
#
# Three sources, one composer (`compose`, pure, tested):
#   heavy-turn --status --json   slots, the memory level, held and waiting tickets
#   ps                           every process: pid, ppid, cpu, rss, age, command
#   the gates runs               each live run's branch, pid and current step
import json
import os
import re
import subprocess
import time
from . import ctx

IDLE_AFTER_S = 15 * 60      # a holder whose tree has done nothing this long holds, not works
IDLE_CPU = 2.0              # % — ps's decaying average; below it a tree is idle
LSP = re.compile(r"\s--lsp(\s|$)")
HEAVY = re.compile(r"(^|/)(tsc|tsgo|seed-gen|oxlint)(\s|$)|swift(-frontend|-build| build)|node .*--test\b")


def heavy_turn():
    """heavy-turn's own status, as it prints it with --json; empty when it can't answer."""
    try:
        out = subprocess.run([os.path.join(ctx.SCRIPTS, "heavy-turn"), "--status", "--json"],
                             capture_output=True, text=True, timeout=10).stdout
        return json.loads(out or "{}")
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {}


def processes():
    """Every process as {pid, ppid, cpu, rssMb, age, command}; same user only (ps -x)."""
    out = subprocess.run(["ps", "-xo", "pid=,ppid=,pcpu=,rss=,etime=,command="], capture_output=True, text=True).stdout
    rows = []
    for ln in out.splitlines():
        parts = ln.split(None, 5)
        if len(parts) < 6:
            continue
        try:
            rows.append({"pid": int(parts[0]), "ppid": int(parts[1]), "cpu": float(parts[2]),
                         "rssMb": int(parts[3]) / 1024, "age": _etime(parts[4]), "command": parts[5]})
        except ValueError:
            continue
    return rows


def _etime(s):
    """ps's ELAPSED ([[dd-]hh:]mm:ss) in seconds."""
    days, _, rest = s.partition("-") if "-" in s else ("0", "", s)
    bits = [int(x) for x in rest.split(":")]
    while len(bits) < 3:
        bits.insert(0, 0)
    return int(days) * 86400 + bits[0] * 3600 + bits[1] * 60 + bits[2]


def gate_runs_now():
    """Each live gates run: its branch, pid and the step it is on."""
    from . import push, gate_queue
    out = []
    for branch, run in push.gate_runs().items():
        if not run.alive():
            continue
        try:
            events = push.gate_events(run)
        except Exception:
            events = []
        standing = None
        try:
            qf = push._queue_file(run)
            if gate_queue.waiting_tier(qf) is not None:
                standing = gate_queue.standing(qf.parent, qf)
        except Exception:
            standing = None
        out.append({"branch": branch, "pid": run.pid, "started": run.started, "step": gate_step(events, standing)})
    return out


def gate_step(events, standing=None):
    """The one word a gate run is at: '2nd in line', 'env (seed-gen)', 'typecheck', 'done'."""
    if standing and standing.get("position"):
        p = standing["position"]
        return f"{p}{'st' if p == 1 else 'nd' if p == 2 else 'rd' if p == 3 else 'th'} in line"
    running = None
    done = set()
    step = ""
    for e in events:
        k = e.get("event")
        if k == "setup":
            step = {"queue": "waiting for a slot", "checkout": "checkout", "env": "env (seed-gen)"}.get(e.get("step"), e.get("step") or "starting")
        elif k == "start":
            running = e.get("gate")
        elif k == "done":
            done.add(e.get("gate"))
            if running == e.get("gate"):
                running = None
        elif k == "result":
            return "done"
    return running or step or "starting"


def _ago(secs):
    return f"{secs // 3600}h {secs % 3600 // 60}m" if secs >= 5400 else f"{secs // 60}m"


def compose(ht, procs, gates, now=None, idle_after=IDLE_AFTER_S):
    """The queue as the Machine page shows it. Pure."""
    now = now or time.time()
    by_pid = {p["pid"]: p for p in procs}
    children = {}
    for p in procs:
        children.setdefault(p["ppid"], []).append(p["pid"])

    def tree(pid):
        out, todo = [], [pid]
        while todo:
            x = todo.pop()
            if x in by_pid and x not in out:
                out.append(x)
                todo += children.get(x, [])
        return out

    def ancestors(pid):
        out = []
        while pid in by_pid and pid not in out:
            out.append(pid)
            pid = by_pid[pid]["ppid"]
        return out

    gate_by_root = {}
    for g in gates:
        for pid in tree(g["pid"]):
            gate_by_root[pid] = g

    def ticket(t, state):
        pid = t.get("pid")
        pids = tree(pid) if pid else []
        cpu = sum(by_pid[x]["cpu"] for x in pids)
        rss = sum(by_pid[x]["rssMb"] for x in pids)
        age = max(0.0, now - (t.get("created") or 0) / 1e9)
        gate = next((gate_by_root[x] for x in (ancestors(pid) + pids) if x in gate_by_root), None)
        cmd = " ".join(t.get("cmd") or []) if isinstance(t.get("cmd"), list) else str(t.get("cmd") or "")
        row = {"id": t.get("id"), "pid": pid, "cls": t.get("cls") or "default", "batch": bool(t.get("batch")),
               "cmd": cmd[:120], "cwd": t.get("cwd") or "", "age": round(age), "state": state,
               "cpu": round(cpu, 1), "rssMb": round(rss), "gate": gate and {"branch": gate["branch"], "step": gate["step"]},
               "idle": state == "held" and age > idle_after and cpu < IDLE_CPU}
        return row

    holders = [ticket(t, "held") for t in ht.get("held") or []]
    waiters = [ticket(t, "waiting") for t in ht.get("waiting") or []]
    queued_pids = set()
    for t in (ht.get("held") or []) + (ht.get("waiting") or []):
        queued_pids.update(tree(t.get("pid")))
    ticket_pids = {t.get("pid") for t in (ht.get("held") or []) + (ht.get("waiting") or [])}
    outside = []
    for p in procs:
        if p["pid"] in queued_pids or not HEAVY.search(p["command"]):
            continue
        # an editor's language server (tsc --lsp under hx) lives as long as the editor: not batch work
        if LSP.search(p["command"]):
            continue
        # a shell whose command line merely names a heavy tool (zsh -c '… tsc …') is not the work
        if os.path.basename(p["command"].split()[0]).lstrip("-") in ("zsh", "bash", "sh", "login", "fish"):
            continue
        # under a ticket, or above one (a run whose child holds the slot): queued either way
        if any(x in queued_pids for x in ancestors(p["pid"])) or any(x in ticket_pids for x in tree(p["pid"])):
            continue
        name = os.path.basename(p["command"].split()[0]) if p["command"] else "?"
        if name in ("node", "python3") and len(p["command"].split()) > 1:
            name = os.path.basename(p["command"].split()[1]) + " (" + name + ")"
        outside.append({"pid": p["pid"], "name": name, "cpu": round(p["cpu"], 1), "rssMb": round(p["rssMb"]), "age": p["age"],
                        "command": p["command"][:120]})
    slots, configured, mem = ht.get("slots", 0), ht.get("configured", 0), ht.get("mem")
    return {
        "slots": slots, "configured": configured, "mem": mem,
        "floor": f"memory {mem}% headroom cut the budget to {slots}" if slots and configured and slots < configured else None,
        "holders": holders, "waiters": waiters,
        "gates": [{"branch": g["branch"], "step": g["step"], "age": round(now - g.get("started", now))} for g in gates],
        "outside": outside,
        "warnings": [f"{h['cmd'] or h['cls']} has held a slot {_ago(h['age'])} with its tree idle — holding, not working" for h in holders if h["idle"]],
    }


def get(req, u):
    answer = compose(heavy_turn(), processes(), gate_runs_now())
    req._send(200, json.dumps({"ok": True, **answer}))


def killable(answer, pid):
    """The row a pid is, if the queue page may kill it: a ticket's own process (held or waiting)
    or heavy work outside the queue — never an arbitrary pid. Pure."""
    for t in answer.get("holders", []) + answer.get("waiters", []):
        if t.get("pid") == pid:
            return {"kind": "ticket", "name": (t.get("gate") or {}).get("branch") or t.get("cmd") or t.get("cls")}
    for o in answer.get("outside", []):
        if o.get("pid") == pid:
            return {"kind": "outside", "name": o.get("name")}
    return None


def kill(req, raw):
    """POST /queue-kill {pid} — Phil's x on a queue row: SIGTERM to a slot holder, a waiter or
    un-queued heavy work; refused for any pid the queue doesn't show."""
    import signal
    d = json.loads(raw or "{}")
    try:
        pid = int(d.get("pid") or 0)
    except (TypeError, ValueError):
        pid = 0
    if pid <= 1:
        return req._send(400, json.dumps({"ok": False, "err": "no pid"}))
    row = killable(compose(heavy_turn(), processes(), gate_runs_now()), pid)
    if not row:
        return req._send(200, json.dumps({"ok": False, "err": f"pid {pid} isn't a slot holder, a waiter or un-queued heavy work — nothing killed"}))
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError as e:
        return req._send(200, json.dumps({"ok": False, "err": f"couldn't signal {pid}: {e.strerror or e}"}))
    req._send(200, json.dumps({"ok": True, "pid": pid, **row}))
