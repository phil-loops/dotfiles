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
# "editing 4h"). Liveness != working. We sample the agent's cumulative CPU time each poll and call
# it "working" only while that keeps advancing — a parked claude burns ~0 CPU. State is in-memory
# (like chat._JOBS); it resets on server restart, re-baselining agents as working. CPU is a proxy:
# a claude BLOCKED on a long model call also burns ~0, so the window is generous on purpose.
_activity = {}          # {claude_pid: {"cpu": float|None, "active_at": int}}
IDLE_SECONDS = 150      # no CPU advance for this long → idle, not working


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
            _reap(path)
            continue
        seen.add(claude_pid)
        cpu = _cpu_seconds(claude_pid)
        prev = _activity.get(claude_pid)
        if prev is None:
            active_at = rec.get("at", now)                                  # just-registered → working
        elif cpu is not None and prev["cpu"] is not None and cpu > prev["cpu"]:
            active_at = now                                                 # CPU advanced → working now
        else:
            active_at = prev["active_at"]                                   # flat → idle since last activity
        _activity[claude_pid] = {"cpu": cpu, "active_at": active_at}
        et = subprocess.run(["ps", "-o", "etime=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        rows.append({"kind": rec.get("kind", "claude"), "branch": rec.get("branch", ""),
                     "repo": rec.get("repo", ""), "pid": pid, "etime": et, "age": _age(rec.get("at")),
                     "active_at": active_at, "working": (now - active_at) < IDLE_SECONDS,
                     "idle_age": _age(active_at)})
    for dead in [p for p in _activity if p not in seen]:                    # forget gone pids — bounded cache
        del _activity[dead]
    # dedupe by (kind, branch): one row per branch with a count. count>1 is a probable duplicate spawn
    # (two agents racing one branch), surfaced like the Hearth's tangle hint.
    grouped = {}
    for r in rows:
        key = (r["kind"], r["branch"])
        g = grouped.get(key)
        if g is None:
            grouped[key] = {**r, "count": 1}
        else:
            g["count"] += 1
            g["working"] = g["working"] or r["working"]
            if r["active_at"] > g["active_at"]:
                g["active_at"], g["age"], g["idle_age"], g["etime"] = r["active_at"], r["age"], r["idle_age"], r["etime"]
    return list(grouped.values())
