# srv/footprint.py — GET /footprint: what this workstation is spending on the tooling, in one
# read-only answer. Three tiers: the machine (memory + swap — the thing that actually kills
# dev, see memory-pressure incidents), the repo's sprawl (registered worktrees, review scratch,
# node_modules clones — the thing that fills swap), and this server's own footprint (RSS,
# threads, live children, cache sizes — so a leak here would be visible instead of assumed).
import json
import os
import re
import resource
import subprocess
import threading
import time

from . import ctx

_T0 = time.time()
_PAGE = 16384


def _vm_stat():
    out = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    d = {}
    for ln in out.splitlines():
        m = re.match(r"([A-Za-z ]+):\s+(\d+)\.?$", ln.strip())
        if m:
            d[m.group(1).strip()] = int(m.group(2))
    mb = lambda k: d.get(k, 0) * _PAGE // 2**20
    return {
        "freeMb": mb("Pages free") + mb("Pages speculative"),
        "activeMb": mb("Pages active"), "inactiveMb": mb("Pages inactive"),
        "wiredMb": mb("Pages wired down"), "compressedMb": mb("Pages occupied by compressor"),
        "swapouts": d.get("Swapouts", 0),
    }


def _swap():
    out = subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True).stdout
    m = re.search(r"total = ([\d.]+)M\s+used = ([\d.]+)M\s+free = ([\d.]+)M", out)
    return {"totalMb": int(float(m.group(1))), "usedMb": int(float(m.group(2)))} if m else {"totalMb": 0, "usedMb": 0}


def _total_mb():
    out = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout.strip()
    return int(out) // 2**20 if out.isdigit() else 0


def _top(n=8):
    # the biggest resident processes — memory pressure is always a few named culprits (OrbStack,
    # browsers, a pile of claude sessions), never a mystery
    out = subprocess.run(["ps", "-axo", "rss=,pid=,pcpu=,comm="], capture_output=True, text=True).stdout
    rows = []
    for ln in out.splitlines():
        p = ln.split(None, 3)
        if len(p) == 4 and p[0].isdigit():
            rows.append({"rssMb": int(p[0]) // 1024, "pid": int(p[1]), "cpu": float(p[2]), "name": os.path.basename(p[3])})
    rows.sort(key=lambda r: -r["rssMb"])
    return rows[:n]


def _self():
    ru = resource.getrusage(resource.RUSAGE_SELF)
    children = subprocess.run(["pgrep", "-P", str(os.getpid())], capture_output=True, text=True).stdout.split()
    from . import review, push, sync, picker
    caches = {
        "commits": len(getattr(review, "_COMMITS_CACHE", {})),
        "commitDiff": len(getattr(review, "_CDIFF_CACHE", {})),
        "pushPreview": len(getattr(push, "_PREVIEW_CACHE", {})),
        "merged": len(getattr(sync, "_MERGED_CACHE", {})),
        "standalone": len(getattr(picker, "_standalone_cache", {})),
    }
    return {
        "pid": os.getpid(), "rssMb": ru.ru_maxrss // 2**20, "threads": threading.active_count(),
        "children": len(children), "uptimeS": int(time.time() - _T0), "caches": caches,
    }


def _repo():
    wts = ctx.run(["git", "worktree", "list", "--porcelain"]).stdout
    paths = [ln[9:] for ln in wts.splitlines() if ln.startswith("worktree ")]
    scratch = [p for p in paths if "/stack-study/" in p]
    home = os.path.expanduser("~/coding")
    nm = 0
    try:
        for d in os.listdir(home):
            if os.path.isdir(os.path.join(home, d, "node_modules")):
                nm += 1
    except OSError:
        pass
    df = subprocess.run(["df", "-k", "/"], capture_output=True, text=True).stdout.splitlines()
    disk = {}
    if len(df) > 1:
        p = df[1].split()
        if len(p) >= 5 and p[1].isdigit():
            disk = {"usedGb": int(p[2]) // 2**20, "totalGb": int(p[1]) // 2**20, "pct": int(p[4].rstrip("%")) if p[4].rstrip("%").isdigit() else 0}
    return {"worktrees": len(paths), "scratch": len(scratch), "nodeModulesClones": nm, "disk": disk}


def get(req, u):
    total = _total_mb()
    vm = _vm_stat()
    swap = _swap()
    # the same thresholds the incident memory names: swap near-full or free < 500MB is the
    # state where next dev dies with 144 — everything else is information, not alarm
    pressure = "critical" if (swap["totalMb"] and swap["usedMb"] / swap["totalMb"] > 0.85) or vm["freeMb"] < 300 \
        else "high" if (swap["totalMb"] and swap["usedMb"] / swap["totalMb"] > 0.6) or vm["freeMb"] < 700 \
        else "ok"
    req._send(200, json.dumps({
        "at": time.time(),
        "machine": {"totalMb": total, "pressure": pressure, **vm, "swap": swap, "top": _top()},
        "repo": _repo(),
        "server": _self(),
    }))
