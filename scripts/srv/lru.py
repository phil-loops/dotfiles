# srv/lru.py — a cache bounded by what it holds, not by how many things.
#
# A count cap bounds nothing when one entry can be a 5 MB diff: 300 of them is 1.5 GB, and a
# long-lived server's heap that size ends up swapped out and paged back in by every full GC.
# Each cache says what an entry weighs; the least recently used go first once the total passes cap.
import json
import threading
from collections import OrderedDict


def json_size(value):
    return len(json.dumps(value, default=str))


class ByteLRU:
    def __init__(self, cap_bytes, size=len):
        self.cap = cap_bytes
        self._size = size
        self._lock = threading.Lock()
        self._items = OrderedDict()   # key -> (value, size)
        self.bytes = 0

    def get(self, key, default=None):
        with self._lock:
            hit = self._items.get(key)
            if hit is None:
                return default
            self._items.move_to_end(key)
            return hit[0]

    def __contains__(self, key):
        with self._lock:
            return key in self._items

    def __len__(self):
        return len(self._items)

    def __setitem__(self, key, value):
        n = self._size(value)
        if n > self.cap // 4:
            return
        with self._lock:
            old = self._items.pop(key, None)
            if old is not None:
                self.bytes -= old[1]
            self._items[key] = (value, n)
            self.bytes += n
            while self.bytes > self.cap and self._items:
                self.bytes -= self._items.popitem(last=False)[1][1]

    def values(self):
        with self._lock:
            return [v for v, _ in self._items.values()]
