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
_BYTE_CAP = 64 << 20
_LOCK = threading.Lock()
_ENTRIES = OrderedDict()   # key -> (built at, value, size)
_bytes = 0
_FLIGHTS = {}              # key -> Event, while a build is running
STATS = {"hit": 0, "miss": 0}


def _size(value):
    parts = value if isinstance(value, tuple) else (value,)
    return sum(len(v) for v in parts if isinstance(v, (str, bytes)))


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
        global _bytes
        size = _size(value)
        now = time.monotonic()
        with _LOCK:
            old = _ENTRIES.pop(key, None)
            if old is not None:
                _bytes -= old[2]
            _ENTRIES[key] = (now, value, size)
            _bytes += size
            while _ENTRIES:
                oldest = next(iter(_ENTRIES.values()))
                if len(_ENTRIES) <= _CAP and _bytes <= _BYTE_CAP and now - oldest[0] < _MAX_AGE:
                    break
                _bytes -= _ENTRIES.popitem(last=False)[1][2]
            STATS["miss"] += 1
        return value
    finally:
        with _LOCK:
            _FLIGHTS.pop(key, None)
        flight.set()
