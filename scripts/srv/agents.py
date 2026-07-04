# srv/agents.py — the ONE registry of fired background agents, for the viewer's Activity dock.
#
# Launching an agent and registering it are the SAME motion: tmux launchers call
# scripts/agent-register, Popen paths call register() here — each drops one record,
# ~/.claude/agents/<pid>.json. /processes reads THIS dir and reaps dead pids, instead of
# reverse-engineering each launch mechanism (claude:/chat: tmux windows, split panes, resolver
# prompt-sig pgrep). A new fire path physically can't go missing, because it can't launch without
# registering — the same taught≡wired property the chat-actions registry has.
#
# This file OWNS the record shape (the cross-lane contract): scripts/agent-register must write the
# identical thing. The old process-tree walk isn't thrown away — it's demoted from *discovery*
# (search the whole system) to a *reaper* (given THIS registered pid, is a claude still alive under
# it?), so its cost is O(1) per record.
import glob
import json
import os
import subprocess
import time

AGENTS_DIR = os.path.expanduser("~/.claude/agents")

# Heartbeat: an agent's process can be alive but parked at its prompt for hours (it read as
# "editing 4h"). Liveness != working. Two signals, whichever is fresher wins (see live()):
#   1. session-presence last_active — hook-updated on real tool activity, no threshold to guess.
#   2. CPU *rate* — for agents with no presence record; gated (~8% of a core) so a parked claude's
#      ~0.5% TUI-loop hum doesn't read as work. CPU state is in-memory (like chat._JOBS) and resets
#      on restart, re-baselining old agents idle until a burst proves them working.
# Both go quiet when a claude is BLOCKED (long model call / slow tool), so the idle window is
# generous on purpose — 150s of NO activity from either signal before an agent reads idle.
_activity = {}            # {claude_pid: {"cpu": float|None, "wall": int, "active_at": int}}
IDLE_SECONDS = 150        # no working-rate burst for this long → idle, not working
CPU_RATE_WORKING = 0.08   # CPU seconds per wall second (~8% of a core) — above the parked-TUI hum
_SAMPLE_MIN = 2           # min wall seconds between rate samples, so fast polls don't spike the rate
LINGER_SECONDS = 900      # a finished agent lingers as a "done" row this long (like chat jobs), then reaps


def _cpu_seconds(pid):
    # Cumulative CPU time (utime+stime) of a pid, in seconds. macOS `ps -o time=` formats it
    # [[DD-]HH:]MM:SS[.ss]; fold the colon groups into seconds. None if the pid is gone.
    out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    days = 0
    if "-" in out:
        d, out = out.split("-", 1)
        days = int(d) if d.isdigit() else 0
    try:
        secs = 0.0
        for part in out.split(":"):
            secs = secs * 60 + float(part)
    except ValueError:
        return None
    return days * 86400 + secs


_PRESENCE_DIR = os.path.expanduser("~/.claude/session-presence")


def _presence_active():
    # {claude_pid: last_active_epoch} from the session-presence registry — a hook-updated activity
    # timestamp every live claude already writes (SessionStart + PostToolUse). It advances on real
    # tool activity, so it needs no CPU threshold: it's the truer "did this agent just do something"
    # signal. Reader-only — no launcher change, because presence bridges pid → last_active for us.
    out = {}
    for path in glob.glob(os.path.join(_PRESENCE_DIR, "*.json")):
        try:
            with open(path) as f:
                r = json.load(f)
        except (OSError, ValueError):
            continue
        pid, la = r.get("pid"), r.get("last_active")
        if pid and la:
            out[pid] = max(out.get(pid, 0), la)
    return out


def _lstart(pid):
    # ps start-time of a pid — the pid-reuse guard. On read we compare it to the record's stored
    # `started`; a mismatch means the pid was recycled onto a different process → the record is
    # stale → reap. Exactly what ~/.claude/session-presence does. Whitespace is COLLAPSED (join on
    # split) to match scripts/agent-register's `awk '{$1=$1}'` — ps double-spaces a single-digit
    # day ("Jul  2"), so without this the shell-written records never match the reader and every
    # launcher's agent would be reaped on sight. The two must normalize identically — it's the contract.
    out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True).stdout
    return " ".join(out.split())


def register(kind, branch, pid, repo="", worktree=""):
    # Python writer, for Popen fire paths (e.g. the restack resolver). Writes the SAME record shape
    # as scripts/agent-register — this file owns the contract, both writers must match it.
    started = _lstart(pid)
    if not started:
        return
    os.makedirs(AGENTS_DIR, exist_ok=True)
    rec = {"kind": kind, "branch": branch, "repo": repo, "pid": int(pid),
           "started": started, "worktree": worktree, "at": int(time.time())}
    with open(os.path.join(AGENTS_DIR, f"{pid}.json"), "w") as f:
        json.dump(rec, f)


def _claude_alive_under(pid):
    # REAPER, not discovery: given a registered pane/wrapper pid, is a claude/node still alive in its
    # process tree? Walk descendants (a pane's tree is tiny) — reconcile/popout run claude as a direct
    # child, the resolver a level or two deeper. None → the agent finished though its shell lingers.
    seen, stack = set(), [int(pid)]
    while stack:
        p = stack.pop()
        if p in seen:
            continue
        seen.add(p)
        comm = subprocess.run(["ps", "-o", "comm=", "-p", str(p)], capture_output=True, text=True).stdout.strip()
        if os.path.basename(comm) in ("claude", "node"):
            return p
        kids = subprocess.run(["pgrep", "-P", str(p)], capture_output=True, text=True).stdout.split()
        stack.extend(int(k) for k in kids if k.isdigit())
    return None


def _age(at):
    s = max(0, int(time.time() - (at or time.time())))
    return f"{s}s" if s < 60 else f"{s // 60}m" if s < 3600 else f"{s // 3600}h"


def _reap(path):
    try:
        os.remove(path)
    except OSError:
        pass


def live():
    # The reader: every registered agent, minus the dead — pid gone, pid recycled (lstart mismatch),
    # or the agent finished though its shell lingers. Survivors get a heartbeat (working?) and are
    # deduped by (kind, branch) so one branch is one row. No system-wide discovery; each record is a
    # KNOWN pid checked in O(1).
    now = int(time.time())
    presence = _presence_active()          # {claude_pid: last_active} — the hook-updated signal
    rows, seen = [], set()
    for path in glob.glob(os.path.join(AGENTS_DIR, "*.json")):
        try:
            with open(path) as f:
                rec = json.load(f)
        except (OSError, ValueError):
            _reap(path)
            continue
        pid = rec.get("pid")
        claude_pid = _claude_alive_under(pid) if pid else None
        if not pid or _lstart(pid) != rec.get("started") or not claude_pid:
            # finished — linger as a "done" row for LINGER_SECONDS (like chat jobs), then reap. The
            # finished_at is stamped into the record, so the linger survives a server restart and
            # can't be re-clocked by re-reads.
            fin = rec.get("finished_at")
            if fin is None:
                fin = now
                rec["finished_at"] = fin
                try:
                    with open(path, "w") as f:
                        json.dump(rec, f)
                except OSError:
                    pass
            if now - fin >= LINGER_SECONDS:
                _reap(path)
                continue
            rows.append({"kind": rec.get("kind", "claude"), "branch": rec.get("branch", ""),
                         "repo": rec.get("repo", ""), "pid": pid, "done": True, "working": False,
                         "age": _age(fin), "active_at": fin})
            continue
        seen.add(claude_pid)
        cpu = _cpu_seconds(claude_pid)
        prev = _activity.get(claude_pid)
        if prev is None:
            active_at = rec.get("at", now)                                  # first sight → assume idle-if-old
            _activity[claude_pid] = {"cpu": cpu, "wall": now, "active_at": active_at}
        elif cpu is None or prev["cpu"] is None or (now - prev["wall"]) < _SAMPLE_MIN:
            active_at = prev["active_at"]                                   # too little interval → carry, don't
            # ...reset the window: leave prev's cpu/wall so the next real sample spans enough time
        else:
            rate = (cpu - prev["cpu"]) / (now - prev["wall"])
            active_at = now if rate > CPU_RATE_WORKING else prev["active_at"]
            _activity[claude_pid] = {"cpu": cpu, "wall": now, "active_at": active_at}
        # hybrid signal: the freshest evidence from EITHER the CPU rate above OR the hook-updated
        # presence last_active. Presence advances on tool activity (no CPU threshold to guess); CPU
        # covers agents with no presence record. Idle only when BOTH have been quiet past the window.
        active_at = max(active_at, presence.get(claude_pid, 0))
        et = subprocess.run(["ps", "-o", "etime=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        rows.append({"kind": rec.get("kind", "claude"), "branch": rec.get("branch", ""),
                     "repo": rec.get("repo", ""), "pid": pid, "etime": et, "age": _age(rec.get("at")),
                     "active_at": active_at, "working": (now - active_at) < IDLE_SECONDS,
                     "idle_age": _age(active_at), "done": False})
    for dead in [p for p in _activity if p not in seen]:                    # forget gone pids — bounded cache
        del _activity[dead]
    # dedupe by (kind, branch): one row per branch, keeping its best member — working beats idle beats
    # done, ties broken by freshest activity. count = total members, so two agents on one branch read
    # x2 (a probable duplicate spawn, surfaced like the Hearth's tangle hint).
    groups = {}
    for r in rows:
        groups.setdefault((r["kind"], r["branch"]), []).append(r)

    def _rank(m):
        tier = 0 if m.get("done") else (2 if m.get("working") else 1)
        return (tier, m.get("active_at", 0))

    return [{**max(members, key=_rank), "count": len(members)} for members in groups.values()]
