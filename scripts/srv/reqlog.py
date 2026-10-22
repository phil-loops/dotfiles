# srv/reqlog.py — the durable request log (<git-common-dir>/stack-review.log) and what goes in it.
#
# Line shape (space-separated; the leading four fields are the pre-2026-10-21 format, so old
# readers still parse it):
#   2026-10-21 17:02:11 POST /push-origin 200 812ms actor=browser sid=8689da45
#   2026-10-21 17:15:00 GET /ext-mtime 200 1ms actor=extension n=412
# On a poll path `n=` counts this hit plus the identical ones folded since that path+actor's
# previous line.
#
# Retention: the old single 5 MB generation held seven days, 83% of it the extension's
# /ext-mtime poll. Polls now coalesce to one line per path+actor per window, the live file
# rotates at 4 MB into gzip'd segments (.1.gz newest), and segments older than 90 days go.
import gzip
import os
import re
import shutil
import threading
import time

LIVE_MAX = 4 * 1024 * 1024
KEEP_DAYS = 90
KEEP_SEGMENTS = 40          # a hard cap even if a burst fills segments faster than 90 days
POLL_WINDOW = 15 * 60

# polled on a timer by a client, not a decision anyone made; errors on them always log
POLLS = ("/ext-mtime", "/gates-progress", "/sig", "/heartbeat", "/processes", "/pulse")

_lock = threading.Lock()
_polls = {}   # (method, path, actor) -> [first_at, count]


def segments(path):
    """Every file of the log, oldest first: .N.gz … .1.gz, a legacy plain .1, then the live file."""
    gz = []
    for name in os.listdir(os.path.dirname(path) or "."):
        m = re.fullmatch(re.escape(os.path.basename(path)) + r"\.(\d+)\.gz", name)
        if m:
            gz.append((int(m.group(1)), os.path.join(os.path.dirname(path), name)))
    out = [p for _, p in sorted(gz, reverse=True)]
    if os.path.exists(path + ".1"):
        out.append(path + ".1")
    if os.path.exists(path):
        out.append(path)
    return out


def _rotate(path):
    d, base = os.path.dirname(path), os.path.basename(path)
    nums = sorted((int(m.group(1)) for m in (re.fullmatch(re.escape(base) + r"\.(\d+)\.gz", n)
                                             for n in os.listdir(d)) if m), reverse=True)
    for n in nums:
        os.replace(f"{path}.{n}.gz", f"{path}.{n + 1}.gz")
    # the pre-gzip scheme's lone plain .1 generation joins the chain as its oldest segment
    if os.path.exists(path + ".1"):
        _gzip(path + ".1", f"{path}.{(nums[0] + 2) if nums else 2}.gz")
    _gzip(path, f"{path}.1.gz")
    cutoff = time.time() - KEEP_DAYS * 86400
    for i, seg in enumerate(sorted((p for p in segments(path) if p.endswith(".gz")),
                                   key=lambda p: int(p.rsplit(".", 2)[-2]))):
        if i >= KEEP_SEGMENTS or os.path.getmtime(seg) < cutoff:
            os.remove(seg)


def _gzip(src, dst):
    mtime = os.path.getmtime(src)
    with open(src, "rb") as fi, gzip.open(dst, "wb") as fo:
        shutil.copyfileobj(fi, fo)
    os.utime(dst, (mtime, mtime))   # a segment's age is its newest line's, for the 90-day prune
    os.remove(src)


def append(path, msg):
    if not path:
        return
    with _lock:
        try:
            if os.path.exists(path) and os.path.getsize(path) > LIVE_MAX:
                _rotate(path)
            with open(path, "a") as f:
                f.write(msg)
        except Exception:
            pass   # a full disk or permissions hiccup must never take a request down


def request_line(method, path, status, ms, actor=None, sid=None):
    """The line to log for one request, or None when it folds into a coalesced poll line."""
    tail = f" actor={actor}" if actor else ""
    if sid:
        tail += f" sid={sid}"
    route = path.split("?", 1)[0]
    if route in POLLS and str(status).startswith("2"):
        key = (method, route, actor)
        now = time.time()
        with _lock:
            slot = _polls.get(key)
            if slot and now - slot[0] < POLL_WINDOW:
                slot[1] += 1
                return None
            n = (slot[1] if slot else 0) + 1
            _polls[key] = [now, 0]
        return f"{method} {route} {status} {ms:.0f}ms{tail} n={n}"
    return f"{method} {path} {status} {ms:.0f}ms{tail}"

