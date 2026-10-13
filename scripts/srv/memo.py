# srv/memo.py — exact-key memo for read-only endpoint payloads.
#
# The key IS the invalidation rule: a caller builds it from every input the payload reads
# (ref tips, config block, dirt stamp, PR membership), so a hit is the payload a fresh build
# would produce. Single-flight per key — the node page fires the same GET from several panels
# and the pulse refetches all of them at once, and N identical builds in parallel are N times
# the spawns for one answer. _MAX_AGE is the net for an input a key forgot.
import threading
import time
from collections import OrderedDict

_MAX_AGE = 120.0
_CAP = 512
_LOCK = threading.Lock()
_ENTRIES = OrderedDict()   # key -> (built at, value)
_FLIGHTS = {}              # key -> Event, while a build is running
STATS = {"hit": 0, "miss": 0}


def get(key, build, keep=lambda value: True):
    """build()'s value for key — memoised, single-flight. build must be read-only; a value
    keep() rejects (a failed build) is returned but not stored."""
    while True:
        with _LOCK:
            hit = _ENTRIES.get(key)
            if hit and time.monotonic() - hit[0] < _MAX_AGE:
                _ENTRIES.move_to_end(key)
                STATS["hit"] += 1
                return hit[1]
            flight = _FLIGHTS.get(key)
            if flight is None:
                flight = _FLIGHTS[key] = threading.Event()
                break
        flight.wait()
    try:
        value = build()
        if not keep(value):
            return value
        with _LOCK:
            _ENTRIES[key] = (time.monotonic(), value)
            _ENTRIES.move_to_end(key)
            while len(_ENTRIES) > _CAP:
                _ENTRIES.popitem(last=False)
            STATS["miss"] += 1
        return value
    finally:
        with _LOCK:
            _FLIGHTS.pop(key, None)
        flight.set()
