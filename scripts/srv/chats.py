"""srv/chats.py — each live Claude Code chat and the work it is bound to (DESIGN.md round 27).

One `chat` per live session in the presence registry (~/.claude/session-presence), keyed by its
full session id:

  works      the work its journal binding names now: each with its todo id, repo and branch label,
             so a view matches a branch by its `work` (branch.<n>.stack-work), never by name. Empty
             means unbound; the chat's cwd is where it stands, never what it works on (P1)
  generation the binding generation this was read at — a click that binds sends it back (P7)
  at         where it stands: the presence record's repo name and branch, for the unbound list
  pane       its tmux pane, to focus; absent outside tmux
  activeAt   its last tool call; live vs idle is the reader's call, and an ended chat is absent
  acted      the branches it acted on within ACTED_WITHIN, newest first: {branch: "<repo>:<name>",
             how: edit | commit, at} — an edit from its presence record (resolved at the edit), a
             commit from the repo's usage log when the chat made it and it wasn't a replay (round 28)

Liveness is the presence record's process (pid + start time); the journal is read read-only and
never created. A journal that can't be read says so on every chat (`works: null`) rather than
reading as unbound.
"""
import glob
import json
import os
import re
import fcntl
import subprocess
import time

from . import agents, ctx, workfresh, workjournal as wj

SOURCE = wj.CLAUDE_CODE_SOURCE
ACTED_WITHIN = 2 * 3600
USAGE_TAIL = 512 * 1024
_COMMON = {}   # repo path -> its git common dir


def dismissals_path():
    return os.environ.get("CANOPY_CHAT_DISMISSALS") or os.path.expanduser("~/.local/state/canopy/chat-dismissals.json")


def _dismissals(now):
    """[{session, branch, at}] Phil dismissed within ACTED_WITHIN: older ones can't outrank any evidence still served."""
    try:
        with open(dismissals_path()) as f:
            return [d for d in json.load(f) if d.get("at", 0) >= now - ACTED_WITHIN]
    except (OSError, ValueError):
        return []


def _usage_logs():
    """{repo name: its stack-usage.jsonl} for every repo the viewer serves."""
    out = {}
    for name, path in (ctx.REPOS or {}).items():
        if path not in _COMMON:
            r = subprocess.run(["git", "-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"], capture_output=True, text=True)
            _COMMON[path] = r.stdout.strip() if r.returncode == 0 else ""
        if _COMMON[path]:
            out[name] = os.path.join(_COMMON[path], "stack-usage.jsonl")
    return out


def _commits(since):
    """[(full session id or its prefix, '<repo>:<branch>', ts)] for commits a chat made since `since`,
    replays excluded: only the log's tail is read, never its history."""
    out = []
    for name, log in _usage_logs().items():
        try:
            with open(log, "rb") as f:
                start = max(0, os.path.getsize(log) - USAGE_TAIL)
                f.seek(start)
                lines = f.read().decode("utf-8", "replace").splitlines()[1 if start else 0:]
        except OSError:
            continue
        for line in lines:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if (e.get("type") == "commit" and e.get("actor") == "claude" and e.get("session") and not e.get("replay")
                    and e.get("branch") and (e.get("ts") or 0) >= since):
                out.append((e.get("sessionId") or e["session"], f"{name}:{e['branch']}", e["ts"]))
    return out


def _acted(r, commits, now, dismissed=()):
    since = now - ACTED_WITHIN
    best = {}
    for branch, ev in (r.get("acted") or {}).items():
        at = (ev or {}).get("edit") or 0
        if at >= since:
            best[branch] = {"branch": branch, "how": "edit", "at": at, **({"work": ev["work"]} if ev.get("work") else {})}
    for who, branch, at in commits:
        # a full id matches exactly; an older row's eight-character prefix is the best it recorded
        if (r["session_id"] == who if len(who) > 8 else r["session_id"].startswith(who)) and at >= best.get(branch, {}).get("at", 0):
            best[branch] = {"branch": branch, "how": "commit", "at": at}
    # a dismissal hides what evidence drew until the chat acts there again (round 28, P6)
    gone = {d["branch"]: d["at"] for d in dismissed if d.get("session") == r["session_id"]}
    return sorted((a for a in best.values() if a["at"] > gone.get(a["branch"], -1)), key=lambda a: -a["at"])


def presence_dir():
    return os.environ.get("CLAUDE_SESSION_PRESENCE_DIR") or os.path.expanduser("~/.claude/session-presence")


def _records():
    out = []
    for f in sorted(glob.glob(os.path.join(presence_dir(), "*.json"))):
        try:
            with open(f) as fh:
                out.append(json.load(fh))
        except (OSError, ValueError):
            continue
    return out


def _running(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except PermissionError:
        return True
    except (OSError, ValueError, TypeError):
        return False


def fingerprint():
    """Moves when a presence record is written or removed, or a chat's process ends (which writes
    nothing). The journal's own fingerprint rides beside this in the todo domain."""
    out = []
    for f in sorted(glob.glob(os.path.join(presence_dir(), "*.json"))):
        try:
            st = os.stat(f)
        except OSError:
            continue
        out.append((os.path.basename(f), st.st_mtime_ns))
    logs = []
    for log in [*_usage_logs().values(), dismissals_path()]:
        try:
            st = os.stat(log)
            logs.append((st.st_size, st.st_mtime_ns))
        except OSError:
            logs.append(None)
    # links fade with time alone, so the minute moves it too
    return (tuple(out) + tuple((r.get("session_id"), _running(r.get("pid"))) for r in _records())
            + tuple(logs) + (int(time.time() // 60),))


def bind(req, raw):
    """POST /chat-bind {session, branch, generation} — Phil's click adds a branch's work to a chat's
    binding, decided from the binding generation his view showed: any other answers 409 with the
    binding now, never overwriting a decision made since he looked (round 27, P7)."""
    from . import reshape, state
    try:
        d = json.loads(raw or "{}")
        session, branch, generation = d.get("session") or "", d.get("branch") or "", d.get("generation")
        if not wj.SESSION_ID.fullmatch(session) or not isinstance(generation, int) or not re.fullmatch(r"[\w./-]+", branch):
            raise ValueError("chat-bind takes {session: a full session id, branch, generation: an integer}")
        work = reshape.work_of(branch)
        j = wj.Journal()
        try:
            if not j.db.execute("SELECT 1 FROM source WHERE source_id = ?", (SOURCE,)).fetchone():
                j.register_source(SOURCE, adapter="claude-code", ordering="none")
            gen = j.bind(SOURCE, session, [work], by="phil", add=True, expect_generation=generation)
        finally:
            j.close()
    except wj.Stale as e:
        return req._send(409, json.dumps({"ok": False, "err": "the chat's binding changed since you looked", "current": e.current}))
    except (reshape.Refused, wj.JournalError, ValueError) as e:
        return req._send(400, json.dumps({"ok": False, "err": str(e)}))
    state.poke()
    return req._send(200, json.dumps({"ok": True, "work": work, "generation": gen}))


def dismiss(req, raw):
    """POST /chat-dismiss {session, branch: "<repo>:<name>"} — Phil's click: the chat isn't on that branch,
    whatever its evidence says, until it acts there again."""
    from . import state
    try:
        d = json.loads(raw or "{}")
        session, branch = d.get("session") or "", d.get("branch") or ""
        if not wj.SESSION_ID.fullmatch(session) or not re.fullmatch(r"[\w.-]+:[\w./-]+", branch):
            raise ValueError("chat-dismiss takes {session: a full session id, branch: <repo>:<name>}")
    except ValueError as e:
        return req._send(400, json.dumps({"ok": False, "err": str(e)}))
    path = dismissals_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        now = time.time()
        kept = [x for x in _dismissals(now) if (x.get("session"), x.get("branch")) != (session, branch)]
        tmp = f"{path}.{os.getpid()}.tmp"
        with open(tmp, "w") as f:
            json.dump(kept + [{"session": session, "branch": branch, "at": now}], f)
        os.replace(tmp, path)
    state.poke()
    return req._send(200, json.dumps({"ok": True}))


def _is_live(r):
    """The record's process is the one that wrote it: running, and started when the record says."""
    return bool(r.get("session_id")) and _running(r.get("pid")) \
        and agents._lstart(r["pid"]) == " ".join(str(r.get("start_time", "")).split())


def live(session):
    """The presence record of a live chat by its full session id, else None."""
    return next((r for r in _records() if r.get("session_id") == session and _is_live(r)), None)


def entities():
    live = [r for r in _records() if _is_live(r)]
    bound, error = {}, None
    try:
        j = wj.Journal(readonly=True)
    except wj.Absent:
        j = None
    except workfresh.UNREADABLE as e:
        j, error = None, e
    if j is not None:
        try:
            with j.snapshot():
                for r in live:
                    b = j.binding(SOURCE, r["session_id"])
                    if b:
                        bound[r["session_id"]] = {"generation": b["generation"], "works": [
                            {"work": w["work_id"], "todo": w["todo_id"], "repo": w["repo"], "branch": w["branch"]}
                            for w in map(j.work, b["works"]) if w and not w["retired_at"]]}
        except workfresh.UNREADABLE as e:
            bound, error = {}, e
        finally:
            j.close()
    now = time.time()
    commits = _commits(now - ACTED_WITHIN)
    dismissed = _dismissals(now)
    chats = {}
    for r in live:
        sid = r["session_id"]
        b = bound.get(sid, {"generation": 0, "works": []})
        chats[sid] = {"id": sid, "works": None if error else b["works"], "generation": b["generation"],
                      "at": {"repo": r.get("repo_name") or "", "branch": r.get("branch") or ""},
                      "pane": r.get("tmux_pane") or None, "activeAt": r.get("last_active") or 0,
                      "acted": _acted(r, commits, now, dismissed),
                      **({"bindingError": f"work journal unreadable: {type(error).__name__}"} if error else {})}
    return {"chat": chats}
