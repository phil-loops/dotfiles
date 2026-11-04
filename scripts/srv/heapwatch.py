# srv/heapwatch.py — make a slow garbage collection loud.
#
# A full collection walks every live container while holding the GIL, so every request waits on it.
# On a heap the OS has swapped out that walk pages it all back in: the 2026-11-04 /node stalls were
# 10-25s of this and nothing said so. Each full collection over the threshold is logged with its
# pause and the number of tracked objects, so the access log's slow minutes can be matched to it.
import gc
import time

from . import ctx

SLOW_MS = 200
STATS = {"full": 0, "slow": 0, "worst_ms": 0.0, "last_ms": 0.0}
_started = [0.0]


def _callback(phase, info):
    if info.get("generation") != 2:
        return
    if phase == "start":
        _started[0] = time.perf_counter()
        return
    ms = (time.perf_counter() - _started[0]) * 1000
    STATS["full"] += 1
    STATS["last_ms"] = ms
    STATS["worst_ms"] = max(STATS["worst_ms"], ms)
    if ms >= SLOW_MS:
        STATS["slow"] += 1
        ctx.log(f"gc: full collection {ms:.0f}ms · {len(gc.get_objects())} tracked objects · {info.get('collected', 0)} freed")


def install():
    if _callback not in gc.callbacks:
        gc.callbacks.append(_callback)
