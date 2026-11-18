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

Liveness is the presence record's process (pid + start time); the journal is read read-only and
never created. A journal that can't be read says so on every chat (`works: null`) rather than
reading as unbound.
"""
import glob
import json
import os
import re

from . import agents, workfresh, workjournal as wj

SOURCE = wj.CLAUDE_CODE_SOURCE


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
    return tuple(out) + tuple((r.get("session_id"), _running(r.get("pid"))) for r in _records())


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


def entities():
    live = [r for r in _records() if r.get("session_id") and _running(r.get("pid"))
            and agents._lstart(r["pid"]) == " ".join(str(r.get("start_time", "")).split())]
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
    chats = {}
    for r in live:
        sid = r["session_id"]
        b = bound.get(sid, {"generation": 0, "works": []})
        chats[sid] = {"id": sid, "works": None if error else b["works"], "generation": b["generation"],
                      "at": {"repo": r.get("repo_name") or "", "branch": r.get("branch") or ""},
                      "pane": r.get("tmux_pane") or None, "activeAt": r.get("last_active") or 0,
                      **({"bindingError": f"work journal unreadable: {type(error).__name__}"} if error else {})}
    return {"chat": chats}
