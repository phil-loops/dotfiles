# srv/second_reader.py — run stack-second-reader when a PR gets a new review. Off unless
# `git config stack.second-reader true` in the repo.
#
# No poller of its own: packet._fetch_remote (the open-PR read the outbox already does every
# ~2 min, covering Phil's stack PRs and imported review/pr-N branches) hands each parsed PR to
# on_pr. A PR whose review list or head moved since the last look is queued; one runner at a time
# drains the queue (the runner itself admits at most 2 claude runs machine-wide and waits out
# memory pressure). The runner only reads GitHub and writes notes under
# <git-common-dir>/stack-review-notes/.
import json
import os
import queue
import subprocess
import threading
import time

from . import ctx

MEM_FLOOR = 30
RUN_TIMEOUT = 1800
_ENABLED_TTL = 30

_seen = {}          # (repo, pr) -> (latest review id, review count, head) last queued
_queued = set()
_q = queue.Queue()
_worker = [None]
_lock = threading.Lock()
_enabled = {}       # repo -> (checked_at, bool)


def enabled(repo):
    hit = _enabled.get(repo)
    if hit and time.time() - hit[0] < _ENABLED_TTL:
        return hit[1]
    on = ctx.run(["git", "-C", repo, "config", "--bool", "stack.second-reader"]).stdout.strip() == "true"
    _enabled[repo] = (time.time(), on)
    return on


def _mem_level():
    r = subprocess.run(["sysctl", "-n", "kern.memorystatus_level"], capture_output=True, text=True)
    try:
        return int(r.stdout.strip())
    except ValueError:
        return 100


def on_pr(repo, full):
    """Called from packet._fetch_remote with one PR as ghreview.parse_pr shaped it."""
    try:
        reviews = full.get("reviews") or []
        if full.get("state", "OPEN") != "OPEN" or not reviews or not enabled(repo):
            return
        key, mark = (repo, full["number"]), (reviews[-1].get("id"), len(reviews), full.get("head"))
        with _lock:
            if _seen.get(key) == mark or key in _queued:
                return
            _queued.add(key)
            _seen[key] = mark
        _q.put(key)
        _ensure_worker()
    except Exception as e:   # a hook must never break the PR-state read it rides on
        ctx.log(f"second-reader: hook failed: {e!r}")


def _ensure_worker():
    with _lock:
        if _worker[0] and _worker[0].is_alive():
            return
        _worker[0] = threading.Thread(target=_drain, daemon=True)
        _worker[0].start()


def _drain():
    while True:
        repo, number = _q.get()
        try:
            if _mem_level() < MEM_FLOOR:
                ctx.log(f"second-reader: #{number} deferred (memory {_mem_level()}% < {MEM_FLOOR}%)")
                with _lock:
                    _seen.pop((repo, number), None)   # the next refresh re-queues it
                continue
            cmd = [os.path.join(ctx.SCRIPTS or os.path.expanduser("~/.dotfiles/scripts"), "stack-second-reader"),
                   str(number), "--repo", repo]
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=RUN_TIMEOUT, start_new_session=True)
            tail = (r.stdout.strip().splitlines() or [""])[-1]
            ctx.log(f"second-reader: #{number} exit {r.returncode} {tail[:200]} {(r.stderr or '').strip()[-300:]}")
            if r.returncode != 0:
                with _lock:
                    _seen.pop((repo, number), None)
            else:
                ctx.bump_pulse()
        except subprocess.TimeoutExpired:
            ctx.log(f"second-reader: #{number} timed out after {RUN_TIMEOUT}s")
        except Exception as e:
            ctx.log(f"second-reader: #{number} failed: {e!r}")
        finally:
            with _lock:
                _queued.discard((repo, number))


def notes(repo, number):
    """{thread-id: note, "_unflagged": {...}} for one PR — for a surface that wants them."""
    common = ctx.run(["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"]).stdout.strip()
    d = os.path.join(common, "stack-review-notes", str(number))
    out = {}
    for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if f.endswith(".json") and not f.startswith("."):
            try:
                with open(os.path.join(d, f)) as fh:
                    out[f[:-5]] = json.load(fh)
            except (OSError, ValueError):
                pass
    return out
