"""One owning chat per forest (forest-ownership design, memory project_forest-ownership-design.md).

A forest's owner is the Claude Code conversation that may write to it: its branch refs, its
membership config, its registry. The record lives in the repo's git config beside the forest's
other keys:

  stack-project.<p>.owner             the owner's full conversation id
  stack-project.<p>.owner-generation  bumped by every change, so a stale decision is refused
  stack-project.<p>.owner-at / -by    when, and who made the change

Authority (P1'): the caller's full conversation id equals the owner's, and that conversation's
presence record (~/.claude/session-presence/<id>.json) is live — its pid runs with the recorded
start time and no newer conversation took that pid (/clear). A process change is not a transfer.

Who's asking (P4'): an explicit STACK_INITIATOR ("claude:<id>", "phil", "maintenance:<name>",
"unknown"), else the chat's own CLAUDE_CODE_SESSION_ID, else nobody identified. Refusal needs a
caller positively identified as a chat; a caller that's neither chat nor Phil is never refused here.

Mode, `git config stack.forest-owner-mode`: "warn" (default) says what it would refuse and records
it in <git-common-dir>/forest-owner-observations.jsonl; "enforce" refuses; "off" says nothing."""
import glob
import json
import os
import subprocess
import time

PRESENCE = os.environ.get("CLAUDE_SESSION_PRESENCE_DIR") or os.path.expanduser("~/.claude/session-presence")
CHECKED = "STACK_OWNER_CHECKED"
_SCRUB = ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE", "GIT_PREFIX")


class Refused(Exception):
    """A write this caller may not make; str() says whose forest it is and what to do instead."""


def _git(cwd, *args):
    env = {k: v for k, v in os.environ.items() if k not in _SCRUB}
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, env=env)


def _cfg(cwd, key):
    return _git(cwd, "config", "--get", key).stdout.strip()


def project_of(cwd, branch):
    return _cfg(cwd, f"branch.{branch}.stack-project")


def initiator(env=None):
    """("claude", <full id>) | ("phil", None) | ("maintenance", <name>) | ("unknown", None)."""
    env = os.environ if env is None else env
    explicit = (env.get("STACK_INITIATOR") or "").strip()
    if explicit:
        kind, _, rest = explicit.partition(":")
        if kind == "claude" and rest:
            return "claude", rest
        if kind in ("phil", "maintenance"):
            return kind, rest or None
        return "unknown", None
    sid = (env.get("CLAUDE_CODE_SESSION_ID") or "").strip()
    return ("claude", sid) if sid else ("unknown", None)


def initiator_text(who):
    kind, ident = who
    return f"{kind}:{ident}" if ident else kind


def _lstart(pid):
    out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True).stdout
    return " ".join(out.split())


def live(session, presence_dir=None):
    """True when the conversation's presence record names a running process with its recorded start
    time, and no newer conversation has since started in that process (a /clear ends this one)."""
    base = presence_dir or PRESENCE
    try:
        with open(os.path.join(base, f"{session}.json")) as f:
            rec = json.load(f)
    except (OSError, ValueError):
        return False
    pid, start = rec.get("pid"), " ".join(str(rec.get("start_time", "")).split())
    if not pid or not start or _lstart(pid) != start:
        return False
    mine = _started(rec)
    for path in glob.glob(os.path.join(base, "*.json")):
        if os.path.basename(path) == f"{session}.json":
            continue
        try:
            with open(path) as f:
                other = json.load(f)
        except (OSError, ValueError):
            continue
        if other.get("pid") == pid and _started(other) > mine:
            return False
    return True


def _started(rec):
    try:
        return float(rec.get("started_at") or 0)
    except (TypeError, ValueError):
        return 0.0


def owner(cwd, project):
    """{"session", "generation", "at", "by"} for the project's owner record, or None."""
    session = _cfg(cwd, f"stack-project.{project}.owner")
    if not session:
        return None
    gen = _cfg(cwd, f"stack-project.{project}.owner-generation")
    return {"session": session, "generation": int(gen) if gen.isdigit() else 0,
            "at": _cfg(cwd, f"stack-project.{project}.owner-at"), "by": _cfg(cwd, f"stack-project.{project}.owner-by")}


def generation(cwd, project):
    gen = _cfg(cwd, f"stack-project.{project}.owner-generation")
    return int(gen) if gen.isdigit() else 0


def verdict(cwd, project, who=None, is_live=live):
    """("ok", why) | ("unowned", why) | ("foreign", why) for `who` writing to `project`."""
    kind, ident = who or initiator()
    if not project:
        return "ok", "not a forest"
    if kind != "claude":
        return "ok", f"{kind} isn't refused by ownership"
    rec = owner(cwd, project)
    if rec and rec["session"] == ident:
        if is_live(ident):
            return "ok", "owner"
        return "unowned", f"{project}'s owner record names this conversation, but its presence record isn't live"
    if rec and is_live(rec["session"]):
        return "foreign", (f"{project} is owned by chat {rec['session'][:8]} (live) — send it the change "
                           f"(claude-say {rec['session'][:8]} …) instead of writing it here")
    if rec:
        return "unowned", f"{project}'s owner {rec['session'][:8]} has ended — `forest-own adopt {project}` to take it"
    return "unowned", f"{project} has no owner — `forest-own adopt {project}` to take it"


def mode(cwd):
    m = _cfg(cwd, "stack.forest-owner-mode") or "warn"
    return m if m in ("off", "warn", "enforce") else "warn"


def _observations(cwd):
    common = _git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()
    return os.path.join(common, "forest-owner-observations.jsonl") if common else ""


def observe(cwd, record):
    path = _observations(cwd)
    if not path:
        return
    try:
        with open(path, "a") as f:
            f.write(json.dumps(record, sort_keys=True) + "\n")
    except OSError:
        pass


def guard(cwd, project, op, layer, branches=(), who=None, out=None, is_live=live):
    """Check a write to `project` before its first mutation. warn: says it on `out` (stderr) and
    records it; enforce: raises Refused; off: nothing. Returns the verdict."""
    out = out if out is not None else _stderr
    try:
        m = mode(cwd)
        who = who or initiator()
        v, why = verdict(cwd, project, who, is_live=is_live)
    except Exception as e:  # a broken check never blocks a write; it says so
        out(f"forest-own: couldn't check {project} ({e}) — not checked")
        return "ok"
    if v == "ok" or m == "off":
        return v
    observe(cwd, {"at": int(time.time()), "mode": m, "verdict": v, "project": project, "op": op, "layer": layer,
                  "branches": list(branches), "initiator": initiator_text(who), "why": why})
    if m == "enforce":
        raise Refused(why)
    out(f"forest-own (warn): {op} on {project} — {why}")
    return v


def _stderr(line):
    import sys
    print(line, file=sys.stderr)


def set_owner(cwd, project, session, expect_generation, by):
    """Point the project's owner at `session` (None clears it), refusing when the generation moved
    since the caller read it. Callers hold the forest's lock."""
    current = generation(cwd, project)
    if expect_generation is not None and current != expect_generation:
        raise Refused(f"{project}'s ownership changed (generation {current}, you read {expect_generation}) — read it again")
    prefix = f"stack-project.{project}"
    if session:
        _ok(cwd, "config", f"{prefix}.owner", session)
    else:
        _git(cwd, "config", "--unset-all", f"{prefix}.owner")
    _ok(cwd, "config", f"{prefix}.owner-generation", str(current + 1))
    _ok(cwd, "config", f"{prefix}.owner-at", time.strftime("%Y-%m-%dT%H:%M:%S%z"))
    _ok(cwd, "config", f"{prefix}.owner-by", by)
    return current + 1


def _ok(cwd, *args):
    r = _git(cwd, *args)
    if r.returncode:
        raise Refused((r.stderr or f"git {args[0]} failed").strip()[:300])


def assign_if_unowned(cwd, project, who=None, is_live=live):
    """The forest-starting motion's assignment (P2): a chat that starts a forest with no live owner
    becomes its owner. Returns the owner's id after, or None when no chat is asking."""
    kind, ident = who or initiator()
    if kind != "claude":
        return None
    rec = owner(cwd, project)
    if rec and (rec["session"] == ident or is_live(rec["session"])):
        return rec["session"]
    set_owner(cwd, project, ident, rec["generation"] if rec else generation(cwd, project), f"stack-reshape new · claude:{ident}")
    return ident
