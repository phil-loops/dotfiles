# srv/telemetry.py — reading the usage log (stack-usage.jsonl) for latency and command metrics.
#
#   GET /telemetry/summary?days=N    slowest commands/surfaces vs budgets, use, refusals, trend, v1 vs v2
#
# Schema-2 events (cmd, nav, registry, page from v2; timing from v1 — see the header of
# scripts/viewer-usage-report) fold into DAILY ROLLUPS cached beside the log
# (<git-common-dir>/stack-telemetry-rollup.json). The fold is incremental: the cache remembers the
# log's inode and the byte offset it has read to, so a dashboard load reads only what was appended
# since the last one. A rotated log (the live file moved to .1.gz) is finished from the segment.
# The raw log rotates by size into gzip segments that are never pruned (rotate_usage).
#
# Pure functions over plain data, importable without a server: scripts/viewer-usage-report
# prints the same summary from the same code.
import datetime as dt
import gzip
import json
import os
import re
import threading
import time

ROLLUP_V = 1
LIVE_MAX = 8 * 1024 * 1024
DEFAULT_BUDGETS = {
    "local": {"feedbackMs": 16.7, "settledMs": None},
    "config-write": {"feedbackMs": 16.7, "settledMs": 300},
    "git-write": {"feedbackMs": 16.7, "settledMs": 3000},
    "slow-io": {"feedbackMs": 16.7, "settledMs": 15000},
}
DEFAULT_PAINT_MS = 100
_LOCK = threading.Lock()


# ── the raw log ────────────────────────────────────────────────────────────

def segments(path):
    """The log's files oldest first: .N.gz … .1.gz, then the live file."""
    d, base = os.path.dirname(path), os.path.basename(path)
    gz = []
    try:
        names = os.listdir(d)
    except OSError:
        return []
    for n in names:
        m = re.fullmatch(re.escape(base) + r"\.(\d+)\.gz", n)
        if m:
            gz.append((int(m.group(1)), os.path.join(d, n)))
    return [p for _, p in sorted(gz, reverse=True)] + ([path] if os.path.exists(path) else [])


def read_events(path, since=0):
    """Every event in the log and its segments with ts >= since, in file order."""
    out = []
    for p in segments(path):
        opener = gzip.open if p.endswith(".gz") else open
        try:
            with opener(p, "rt", errors="replace") as f:
                for line in f:
                    try:
                        e = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(e, dict) and e.get("ts", 0) >= since:
                        out.append(e)
        except OSError:
            continue
    return out


def rotate_usage(path):
    """Past LIVE_MAX, the live log becomes .1.gz (older segments shift up; none are dropped).
    Renamed before it's compressed, so a git hook appending meanwhile lands in the new file."""
    try:
        if os.path.getsize(path) <= LIVE_MAX:
            return
    except OSError:
        return
    nums = sorted((int(p.rsplit(".", 2)[-2]) for p in segments(path) if p.endswith(".gz")), reverse=True)
    for n in nums:
        os.replace(f"{path}.{n}.gz", f"{path}.{n + 1}.gz")
    tmp = path + ".rotating"
    os.replace(path, tmp)
    mtime = os.path.getmtime(tmp)
    with open(tmp, "rb") as fi, gzip.open(f"{path}.1.gz", "wb") as fo:
        while chunk := fi.read(1 << 20):
            fo.write(chunk)
    os.utime(f"{path}.1.gz", (mtime, mtime))
    os.remove(tmp)


# ── daily rollups ──────────────────────────────────────────────────────────

def _day(ts):
    return dt.datetime.fromtimestamp(ts).strftime("%Y-%m-%d")


def _num(v):
    return round(float(v), 1) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def fold(days, reg, e):
    """Fold one event into the per-day rollup. Events that aren't schema 2 are ignored."""
    if e.get("schema") != 2:
        return reg
    t, app = e.get("type"), e.get("app") or "?"
    if t == "registry":
        return e if e.get("ts", 0) >= (reg or {}).get("ts", 0) else reg
    d = days.setdefault(_day(e.get("ts", 0)), {"cmd": {}, "nav": {}, "page": {}})
    if t == "cmd" or (t == "timing" and e.get("kind") == "input"):
        k = f"{app}|{e.get('id') or '?'}"
        c = d["cmd"].setdefault(k, {"budget": e.get("budget") or "local", "n": 0, "via": {}, "out": {}, "err": {}, "fb": [], "st": []})
        c["n"] += 1
        c["budget"] = e.get("budget") or c["budget"]
        for field, key in (("via", e.get("via")), ("out", e.get("outcome") or "ok"), ("err", e.get("err"))):
            if key:
                c[field][key] = c[field].get(key, 0) + 1
        if _num(e.get("feedbackMs")) is not None:
            c["fb"].append(_num(e["feedbackMs"]))
        if _num(e.get("settledMs")) is not None:
            c["st"].append(_num(e["settledMs"]))
    elif t == "nav" or (t == "timing" and e.get("kind") == "nav"):
        k = f"{app}|{e.get('to') or '?'}"
        n = d["nav"].setdefault(k, {"n": 0, "paint": []})
        n["n"] += 1
        if _num(e.get("paintMs")) is not None:
            n["paint"].append(_num(e["paintMs"]))
    elif t == "page":
        p = d["page"].setdefault(app, {"loads": 0, "longtasks": 0, "longtaskMs": [], "cls": []})
        lt = e.get("longtasks") or {}
        p["loads"] += 1
        p["longtasks"] += int(lt.get("n") or 0)
        p["longtaskMs"].append(_num(lt.get("totalMs")) or 0)
        p["cls"].append(_num(e.get("cls")) or 0)
    return reg


def _fold_bytes(cache, data):
    for line in data.splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if isinstance(e, dict):
            cache["registry"] = fold(cache["days"], cache.get("registry"), e)


def rollups(gd):
    """The cached daily rollups, brought up to date with whatever the log gained since."""
    path = os.path.join(gd, "stack-usage.jsonl")
    cpath = os.path.join(gd, "stack-telemetry-rollup.json")
    with _LOCK:
        try:
            with open(cpath) as f:
                cache = json.load(f)
            if cache.get("v") != ROLLUP_V:
                raise ValueError
        except (OSError, ValueError):
            cache = {"v": ROLLUP_V, "ino": None, "off": 0, "days": {}, "registry": None}
        try:
            st = os.stat(path)
        except OSError:
            return cache
        if cache["ino"] is not None and cache["ino"] != st.st_ino:
            # rotated since the last fold: finish the old file from its segment
            try:
                with gzip.open(path + ".1.gz", "rb") as f:
                    f.seek(cache["off"])
                    _fold_bytes(cache, f.read().decode("utf-8", "replace"))
            except OSError:
                pass
            cache["off"] = 0
        if cache["ino"] is None and cache["off"] == 0:
            for seg in segments(path)[:-1]:
                with gzip.open(seg, "rt", errors="replace") as f:
                    _fold_bytes(cache, f.read())
        cache["ino"] = st.st_ino
        if st.st_size > cache["off"]:
            with open(path, "rb") as f:
                f.seek(cache["off"])
                data = f.read()
            end = data.rfind(b"\n") + 1   # a half-written last line waits for the next fold
            _fold_bytes(cache, data[:end].decode("utf-8", "replace"))
            cache["off"] += end
            tmp = cpath + f".{os.getpid()}"
            try:
                with open(tmp, "w") as f:
                    json.dump(cache, f, separators=(",", ":"))
                os.replace(tmp, cpath)
            except OSError:
                pass
        return cache


# ── the summary ────────────────────────────────────────────────────────────

def _pct(xs, q):
    if not xs:
        return None
    s = sorted(xs)
    return s[min(len(s) - 1, int(q * len(s)))]


def _stats(xs):
    return {"n": len(xs), "p50": _pct(xs, 0.5), "p95": _pct(xs, 0.95)}


def _week(day):
    y, w, _ = dt.date.fromisoformat(day).isocalendar()
    return f"{y}-W{w:02d}"


def summarize(cache, days=30, now=None):
    now = now or time.time()
    cutoff = _day(now - days * 86400)
    reg = cache.get("registry") or {}
    budgets = reg.get("budgets") or DEFAULT_BUDGETS
    paint_budget = reg.get("paintMs") or DEFAULT_PAINT_MS
    window = {d: r for d, r in cache.get("days", {}).items() if d > cutoff}

    cmds, navs, pages = {}, {}, {}
    for r in window.values():
        for k, c in r["cmd"].items():
            m = cmds.setdefault(k, {"budget": c["budget"], "n": 0, "via": {}, "out": {}, "err": {}, "fb": [], "st": []})
            m["n"] += c["n"]
            m["budget"] = c["budget"]
            for f in ("via", "out", "err"):
                for kk, v in c[f].items():
                    m[f][kk] = m[f].get(kk, 0) + v
            m["fb"] += c["fb"]
            m["st"] += c["st"]
        for k, n in r["nav"].items():
            m = navs.setdefault(k, {"n": 0, "paint": []})
            m["n"] += n["n"]
            m["paint"] += n["paint"]
        for app, p in r["page"].items():
            m = pages.setdefault(app, {"loads": 0, "longtasks": 0, "longtaskMs": [], "cls": []})
            m["loads"] += p["loads"]
            m["longtasks"] += p["longtasks"]
            m["longtaskMs"] += p["longtaskMs"]
            m["cls"] += p["cls"]

    def over(value, budget):
        return round(value / budget, 2) if value is not None and budget else None

    commands = []
    for k, m in cmds.items():
        app, cid = k.split("|", 1)
        b = budgets.get(m["budget"]) or DEFAULT_BUDGETS["local"]
        fb, st = _stats(m["fb"]), _stats(m["st"])
        ratio = max([x for x in (over(fb["p95"], b["feedbackMs"]), over(st["p95"], b.get("settledMs"))) if x is not None], default=None)
        bad = m["out"].get("refused", 0), m["out"].get("failed", 0)
        commands.append({
            "app": app, "id": cid, "budget": m["budget"], "budgetMs": b, "n": m["n"], "via": m["via"], "outcomes": m["out"],
            "refusedRate": round(bad[0] / m["n"], 3), "failedRate": round(bad[1] / m["n"], 3),
            "topErr": max(m["err"], key=m["err"].get) if m["err"] else None,
            "feedback": fb, "settled": st, "over": ratio,
            "score": round(m["n"] * max(0.0, (ratio or 0) - 1), 2),
        })
    commands.sort(key=lambda c: (-c["score"], -(c["over"] or 0), -c["n"]))

    surfaces = []
    for k, m in navs.items():
        app, sid = k.split("|", 1)
        ps = _stats(m["paint"])
        ratio = over(ps["p95"], paint_budget)
        surfaces.append({"app": app, "id": sid, "n": m["n"], "paint": ps, "over": ratio,
                         "score": round(m["n"] * max(0.0, (ratio or 0) - 1), 2)})
    surfaces.sort(key=lambda s: (-s["score"], -(s["over"] or 0), -s["n"]))

    registered = [c["id"] for c in reg.get("commands") or []]
    used = {c["id"] for c in commands if c["app"] == "v2"}
    by = {(c["app"], c["id"]): c for c in commands}
    sby = {(s["app"], s["id"]): s for s in surfaces}

    def merged(rows):
        rows = [r for r in rows if r]
        if not rows:
            return None
        if len(rows) == 1:
            return rows[0]
        return {"n": sum(r["n"] for r in rows), "ids": [r["id"] for r in rows]}

    pairs = []
    for c in reg.get("commands") or []:
        if c.get("v1"):
            pairs.append({"kind": "cmd", "id": c["id"], "v1ids": c["v1"], "v2": by.get(("v2", c["id"])),
                          "v1": merged([by.get(("v1", v)) for v in c["v1"]])})
    for s in reg.get("surfaces") or []:
        if s.get("v1"):
            pairs.append({"kind": "nav", "id": s["id"], "v1ids": s["v1"], "v2": sby.get(("v2", s["id"])),
                          "v1": merged([sby.get(("v1", v)) for v in s["v1"]])})

    weekly = {}
    for d, r in window.items():
        w = weekly.setdefault(_week(d), {})
        for k, c in r["cmd"].items():
            a = w.setdefault(k.split("|", 1)[0], {"cmds": 0, "fb": [], "st": [], "paint": []})
            a["cmds"] += c["n"]
            a["fb"] += c["fb"]
            a["st"] += c["st"]
        for k, n in r["nav"].items():
            a = w.setdefault(k.split("|", 1)[0], {"cmds": 0, "fb": [], "st": [], "paint": []})
            a["paint"] += n["paint"]
    trend = [{"week": wk, "app": app, "cmds": a["cmds"], "feedbackP95": _pct(a["fb"], 0.95),
              "settledP95": _pct(a["st"], 0.95), "paintP95": _pct(a["paint"], 0.95)}
             for wk, apps in sorted(weekly.items()) for app, a in sorted(apps.items())]

    return {
        "days": days, "generatedAt": int(now), "budgets": budgets, "paintMs": paint_budget,
        "commands": commands, "surfaces": surfaces,
        "mostUsed": sorted(({"app": c["app"], "id": c["id"], "n": c["n"]} for c in commands), key=lambda c: -c["n"])[:15],
        "neverUsed": [i for i in registered if i not in used], "registeredAt": reg.get("ts"),
        "pairs": pairs, "weekly": trend,
        "pages": {app: {"loads": p["loads"], "longtasks": p["longtasks"], "longtaskMsP95": _pct(p["longtaskMs"], 0.95),
                        "clsP95": _pct(p["cls"], 0.95)} for app, p in pages.items()},
    }


def summary(req, u):
    from urllib.parse import parse_qs
    from . import watch
    q = parse_qs(u.query)
    raw = q.get("days", ["30"])[0]
    days = int(raw) if raw.isdigit() and 0 < int(raw) <= 3650 else 30
    t0 = time.perf_counter()
    gd = watch.common_dir()
    body = summarize(rollups(gd), days) if gd else {"err": "no repo"}
    body["ms"] = round((time.perf_counter() - t0) * 1000, 1)
    req._send(200, json.dumps(body))
