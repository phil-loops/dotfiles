# srv/actor.py — who made this request: Phil's browser, a Claude session, the gh-to-nvim
# extension, a headless run, Helix, or a bare CLI. Without it every call looks the same in the
# request log and the usage log, so "Phil did X" and "Claude did X through the server" can't be
# told apart (the 2026-10-21 usage audit's first hole).
#
# Precedence: an explicit X-Stack-Actor header, then the extension's Origin, then the
# User-Agent. A CLI-shaped caller with no header gets its peer process walked to a `claude`
# ancestor (lsof on the client port, ~40ms) — only for non-poll calls, so ad-hoc curls from a
# session attribute themselves without every script having to remember the header.
import glob
import json
import os
import re
import subprocess
import threading
import time

ACTORS = ("browser", "claude", "extension", "cli", "headless", "helix", "server", "unknown")
# Paths only the extension polls/calls; its service-worker fetches may arrive without an Origin.
EXT_PATHS = ("/ext-mtime", "/open-url", "/pr-forest")
# High-rate polls: never worth a peer-process walk, and the request log coalesces them.
POLL_PATHS = ("/ext-mtime", "/gates-progress", "/sig", "/heartbeat", "/events", "/processes",
              "/pulse", "/track")

_CLI_UA = re.compile(r"^(curl|python-urllib|python-requests|wget|httpie|node|undici|go-http|got)\b", re.I)
_HEADLESS_UA = re.compile(r"HeadlessChrome|Playwright|Puppeteer|PhantomJS|jsdom", re.I)
_LOCAL_REF = re.compile(r"^https?://(localhost|127\.0\.0\.1)(:\d+)?(/|$)")

_tl = threading.local()
_peer_cache = {}   # client pid -> (at, (actor, sid))
_PEER_TTL = 600


def classify(headers, path, ext_origins, client_port=None):
    """→ (actor, sid). sid is a Claude session id prefix when one is known, else None."""
    explicit = (headers.get("X-Stack-Actor") or "").strip().lower()
    sid = (headers.get("X-Stack-Session") or "").strip()[:8] or None
    if explicit in ACTORS:
        return explicit, sid
    origin = headers.get("Origin") or ""
    referer = headers.get("Referer") or ""
    if origin in ext_origins or origin.startswith("chrome-extension://") or referer.startswith("chrome-extension://"):
        return "extension", None
    ua = headers.get("User-Agent") or ""
    if _HEADLESS_UA.search(ua):
        return "headless", None
    if ua.startswith("Mozilla/"):
        if path in EXT_PATHS and not _LOCAL_REF.match(referer) and headers.get("Sec-Fetch-Site") != "same-origin":
            return "extension", None
        return "browser", None
    if not ua or _CLI_UA.match(ua):
        if client_port and path not in POLL_PATHS:
            found = _peer_actor(client_port)
            if found:
                return found
        return "cli", None
    return "unknown", None


def _sh(args, timeout=2):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""


def _peer_pid(client_port):
    # both ends of the localhost connection show up; the client end is the pid that isn't us
    me = os.getpid()
    for line in _sh(["lsof", "-nP", f"-iTCP:{client_port}", "-sTCP:ESTABLISHED", "-Fp"]).splitlines():
        if line.startswith("p") and line[1:].isdigit() and int(line[1:]) != me:
            return int(line[1:])
    return None


def _peer_actor(client_port):
    pid = _peer_pid(client_port)
    if not pid:
        return None
    hit = _peer_cache.get(pid)
    if hit and time.time() - hit[0] < _PEER_TTL:
        return hit[1]
    script = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "claude-session-pid")
    out = _sh([script, str(pid)], timeout=3)
    claude_pid = out.split("\t")[0].strip() if out else ""
    found = ("claude", _presence_sid(claude_pid)) if claude_pid else ("cli", None)
    _peer_cache[pid] = (time.time(), found)
    return found


def _presence_sid(claude_pid):
    for f in glob.glob(os.path.expanduser("~/.claude/session-presence/*.json")):
        try:
            with open(f) as fh:
                d = json.load(fh)
        except Exception:
            continue
        if str(d.get("pid")) == claude_pid:
            return (d.get("session_id") or "")[:8] or None
    return None


# The request's actor rides a thread-local (the server is one thread per request) so run() can
# hand it to every git child — the pre-push hook then knows a viewer push was Phil's click or a
# Claude curl without any handler threading it through.
def set_current(actor, sid=None):
    _tl.actor, _tl.sid = actor, sid


def clear_current():
    _tl.actor, _tl.sid = None, None


def current():
    return getattr(_tl, "actor", None), getattr(_tl, "sid", None)


def child_env():
    a, sid = current()
    if not a:
        return None
    env = dict(os.environ, STACK_ACTOR=a, STACK_VIA="viewer")
    if sid:
        env["STACK_SESSION"] = sid
    return env
