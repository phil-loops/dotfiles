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


def _lstart(pid):
    # ps start-time of a pid — the pid-reuse guard. On read we compare it to the record's stored
    # `started`; a mismatch means the pid was recycled onto a different process → the record is
    # stale → reap. Exactly what ~/.claude/session-presence does.
    return subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)],
                          capture_output=True, text=True).stdout.strip()


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
    # or the agent finished though its shell lingers. Survivors normalized for /processes. No
    # system-wide discovery; each record is a KNOWN pid checked in O(1).
    out = []
    for path in glob.glob(os.path.join(AGENTS_DIR, "*.json")):
        try:
            with open(path) as f:
                rec = json.load(f)
        except (OSError, ValueError):
            _reap(path)
            continue
        pid = rec.get("pid")
        if not pid or _lstart(pid) != rec.get("started") or not _claude_alive_under(pid):
            _reap(path)
            continue
        et = subprocess.run(["ps", "-o", "etime=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        out.append({"kind": rec.get("kind", "claude"), "branch": rec.get("branch", ""),
                    "repo": rec.get("repo", ""), "pid": pid, "etime": et, "age": _age(rec.get("at"))})
    return out
