"""learning.py — the learner's concept graph: what there is to learn, how deeply it's held, what's due.

One personal graph, not one map per topic. A **concept** is a single idea with a one-line
statement; it `builds_on` the concepts it needs and lists `analogs` — the same idea met in another
topic, which is what lets the tutor go problem-first where an analog is solid. A **topic** (a PR, a
subsystem) is a path through the graph: ordered stages of concept ids.

Depth comes only from **evidence**, never from a verdict typed by hand:

    level    predict < explain < transfer < critique
    credit   unaided | scaffolded | handed
    outcome  hit | miss

A concept's depth is the highest level shown *unaided* (a higher level implies the lower ones).
Assisted hits above that show as "with help". It is due for a re-test when a miss is still open,
when it has only ever been shown with help, or when its last unaided hit is older than its spacing
interval (which doubles with each further unaided hit).

Stored at ~/.dotfiles/learning/graph.json (versioned). Every write regenerates the "Current state"
section of the learner's memory track, so Claude sessions that only read memory still see it.
CLI: scripts/learn.
"""
import datetime
import fcntl
import glob
import json
import os
import re
import uuid
from contextlib import contextmanager

GRAPH = os.environ.get("LEARNING_GRAPH") or os.path.expanduser("~/.dotfiles/learning/graph.json")
TRACK_NAME = "phil-learning-track"
STATE_HEADING = "## Current state"

LEVELS = ["predict", "explain", "transfer", "critique"]
CREDITS = ["unaided", "scaffolded", "handed"]
OUTCOMES = ["hit", "miss"]
KINDS = ["principle", "convention"]
BASE_SPACING_DAYS = 4
MAX_SPACING_DAYS = 120


class Invalid(ValueError):
    pass


def _today():
    return datetime.date.today().isoformat()


def _empty():
    return {"version": 1, "concepts": {}, "topics": {}, "evidence": [], "questions": [], "calibration": []}


def load(path=None):
    try:
        with open(path or GRAPH, encoding="utf-8") as fh:
            g = json.load(fh)
    except FileNotFoundError:
        return _empty()
    for k, v in _empty().items():
        g.setdefault(k, v)
    return g


def save(g, path=None):
    path = path or GRAPH
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(g, fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, path)


@contextmanager
def editing(path=None, sync_memory=True):
    """Read-modify-write under an exclusive lock; the tab, the CLI and a terminal tutor can race."""
    path = path or GRAPH
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        g = load(path)
        yield g
        save(g, path)
        if sync_memory:
            try:
                write_memory_state(g)
            except OSError:
                pass


def slug(text):
    s = re.sub(r"[^a-z0-9]+", "-", str(text).lower()).strip("-")
    return s[:60] or "concept"


def _uniq(xs):
    out = []
    for x in xs:
        if x and x not in out:
            out.append(x)
    return out


def _clean(s):
    return " ".join(str(s or "").split())


# ── writes ────────────────────────────────────────────────────────────

def upsert_concept(g, c, topic=None):
    if isinstance(c, str):
        c = {"id": c}
    cid = slug(c.get("id") or c.get("name") or "")
    cur = g["concepts"].get(cid)
    if cur is None:
        cur = {"name": _clean(c.get("name")) or cid.replace("-", " "), "statement": "", "kind": "principle",
               "builds_on": [], "analogs": [], "code": [], "topics": [], "created": _today()}
        g["concepts"][cid] = cur
    for key in ("name", "statement"):
        if _clean(c.get(key)):
            cur[key] = _clean(c[key])
    if c.get("kind") in KINDS:
        cur["kind"] = c["kind"]
    cur["builds_on"] = _uniq(cur["builds_on"] + [slug(x) for x in c.get("builds_on") or [] if slug(x) != cid])
    cur["analogs"] = _uniq(cur["analogs"] + [slug(x) for x in c.get("analogs") or [] if slug(x) != cid])
    for ref in c.get("code") or []:
        if isinstance(ref, dict) and ref.get("path") and ref not in cur["code"]:
            cur["code"].append({k: ref[k] for k in ("path", "ref", "lines") if ref.get(k)})
    if topic:
        cur["topics"] = _uniq(cur["topics"] + [topic])
    # an analog runs both ways, whichever side was written first
    for oid, other in g["concepts"].items():
        if oid == cid:
            continue
        if oid in cur["analogs"] and cid not in other["analogs"]:
            other["analogs"].append(cid)
        if cid in other["analogs"] and oid not in cur["analogs"]:
            cur["analogs"].append(oid)
    return cid


def upsert_topic(g, t):
    tid = slug(t.get("id") or t.get("title") or "topic")
    cur = g["topics"].setdefault(tid, {"title": "", "source": "", "stages": [], "created": _today()})
    for key in ("title", "source"):
        if _clean(t.get(key)):
            cur[key] = _clean(t[key])
    if t.get("stages"):
        stages = []
        for st in t["stages"]:
            ids = [upsert_concept(g, c, topic=tid) for c in st.get("concepts") or []]
            stages.append({"name": _clean(st.get("name")) or "stage", "concepts": ids})
        cur["stages"] = stages
    cur["updated"] = _today()
    return tid


def add_evidence(g, e, session="", topic=""):
    cid = slug(e.get("concept") or "")
    if not cid or cid == "concept":
        raise Invalid("evidence needs a concept")
    level, credit, outcome = e.get("level"), e.get("credit", "unaided"), e.get("outcome", "hit")
    if level not in LEVELS or credit not in CREDITS or outcome not in OUTCOMES:
        raise Invalid(f"bad evidence {level}/{credit}/{outcome} — levels {LEVELS}, credits {CREDITS}, outcomes {OUTCOMES}")
    if cid not in g["concepts"]:
        upsert_concept(g, {"id": cid, "name": e.get("name")}, topic=topic or None)
    row = {"id": uuid.uuid4().hex[:10], "concept": cid, "level": level, "credit": credit, "outcome": outcome,
           "note": _clean(e.get("note")), "at": e.get("at") or _today(),
           "topic": slug(topic) if topic else "", "session": session}
    g["evidence"].append(row)
    return row["id"]


def edit_evidence(g, eid, fields):
    for row in g["evidence"]:
        if row["id"] == eid:
            for k in ("level", "credit", "outcome", "note"):
                if k in fields:
                    row[k] = _clean(fields[k]) if k == "note" else fields[k]
            if row["level"] not in LEVELS or row["credit"] not in CREDITS or row["outcome"] not in OUTCOMES:
                raise Invalid("bad evidence fields")
            row["edited"] = _today()
            return row
    raise Invalid(f"no evidence {eid}")


def delete_evidence(g, eid):
    before = len(g["evidence"])
    g["evidence"] = [r for r in g["evidence"] if r["id"] != eid]
    if len(g["evidence"]) == before:
        raise Invalid(f"no evidence {eid}")


def add_question(g, text, concept="", topic=""):
    q = {"id": uuid.uuid4().hex[:10], "text": _clean(text), "concept": slug(concept) if concept else "",
         "topic": slug(topic) if topic else "", "asked": _today(), "status": "open"}
    if not q["text"]:
        raise Invalid("empty question")
    g["questions"].append(q)
    return q["id"]


def set_question(g, qid, status):
    for q in g["questions"]:
        if q["id"] == qid:
            q["status"] = status
            q["closed"] = _today()
            return q
    raise Invalid(f"no question {qid}")


def add_calibration(g, note):
    note = _clean(note)
    if note and note not in [c["note"] for c in g["calibration"]]:
        g["calibration"].append({"note": note, "at": _today()})


# ── reads ─────────────────────────────────────────────────────────────

def _days(a, b):
    return (datetime.date.fromisoformat(b) - datetime.date.fromisoformat(a)).days


def mastery(g, cid, today=None):
    today = today or _today()
    rows = sorted((r for r in g["evidence"] if r["concept"] == cid), key=lambda r: r["at"])
    depth = assisted = 0
    last_unaided = ""
    unaided_hits = 0
    open_miss = None
    for r in rows:
        lvl = LEVELS.index(r["level"]) + 1
        if r["outcome"] == "miss":
            open_miss = r
            continue
        if r["credit"] == "unaided":
            depth = max(depth, lvl)
            last_unaided = r["at"]
            unaided_hits += 1
            if open_miss and lvl >= LEVELS.index(open_miss["level"]) + 1:
                open_miss = None
        else:
            assisted = max(assisted, lvl)
    spacing = min(MAX_SPACING_DAYS, BASE_SPACING_DAYS * 2 ** max(0, unaided_hits - 1) * max(1, depth))
    if open_miss:
        due, reason = True, f"missed: {open_miss['note'] or open_miss['level']}"
    elif depth == 0 and assisted:
        due, reason = True, "only shown with help"
    elif depth and _days(last_unaided, today) > spacing:
        due, reason = True, f"last shown unaided {_days(last_unaided, today)} days ago"
    else:
        due, reason = False, ""
    return {"depth": depth, "assisted": max(assisted, depth), "level": LEVELS[depth - 1] if depth else "",
            "evidence": len(rows), "last": rows[-1]["at"] if rows else "", "due": due, "reason": reason,
            "open_miss": open_miss["note"] if open_miss else "", "spacing": spacing}


def _priority(m):
    # open misses first, then help-only, then the most overdue relative to its spacing
    if m["open_miss"]:
        return (0, 0)
    if m["depth"] == 0:
        return (1, 0)
    return (2, -1)


def state(g, today=None):
    today = today or _today()
    concepts = {cid: {**c, "id": cid, "mastery": mastery(g, cid, today)} for cid, c in g["concepts"].items()}
    for c in concepts.values():
        c["built_on_by"] = sorted(o for o, oc in g["concepts"].items() if c["id"] in oc["builds_on"])
    due = sorted((c for c in concepts.values() if c["mastery"]["due"]),
                 key=lambda c: (_priority(c["mastery"]), c["mastery"]["last"]))
    topics = {}
    for tid, t in g["topics"].items():
        ids = [i for st in t["stages"] for i in st["concepts"]]
        held = sum(1 for i in ids if concepts.get(i, {}).get("mastery", {}).get("depth", 0) >= 2)
        topics[tid] = {**t, "id": tid, "progress": {"held": held, "total": len(ids)}}
    return {"concepts": concepts, "topics": topics, "due": [c["id"] for c in due],
            "questions": g["questions"], "calibration": g["calibration"], "evidence": g["evidence"],
            "levels": LEVELS, "credits": CREDITS, "today": today}


def _depth_label(m):
    if m["depth"]:
        s = m["level"]
        if m["assisted"] > m["depth"]:
            s += f" (+{LEVELS[m['assisted'] - 1]} with help)"
        return s
    return f"{LEVELS[m['assisted'] - 1]} with help only" if m["assisted"] else "not yet shown"


def digest(g, topic=None, today=None):
    """Compact text for a tutor's prompt: the whole graph at a glance, the active topic in full."""
    st = state(g, today)
    out = ["## The learner's concept graph (~/.dotfiles/learning/graph.json)",
           "Depth = highest level shown UNAIDED: predict < explain < transfer < critique.", ""]
    if topic and topic in st["topics"]:
        t = st["topics"][topic]
        out.append(f"### Active topic: {t['title']} [{topic}] — {t['source']}")
        for s in t["stages"]:
            out.append(f"- stage **{s['name']}**: " + ", ".join(
                f"{i} ({_depth_label(st['concepts'][i]['mastery'])})" for i in s["concepts"] if i in st["concepts"]))
        out.append("")
    out.append("### All concepts (id · depth · kind — statement · analogs)")
    for tid, t in st["topics"].items():
        out.append(f"**{t['title']}** [{tid}]")
        for s in t["stages"]:
            for i in s["concepts"]:
                c = st["concepts"].get(i)
                if not c:
                    continue
                an = ", ".join(c["analogs"])
                miss = f" · OPEN MISS: {c['mastery']['open_miss']}" if c["mastery"]["open_miss"] else ""
                out.append(f"- {i} · {_depth_label(c['mastery'])} · {c['kind']} — {c['statement']}"
                           + (f" · analogs: {an}" if an else "") + miss)
    loose = [c for c in st["concepts"].values() if not c["topics"]]
    if loose:
        out.append("**Not on any topic yet**")
    for c in loose:
        out.append(f"- {c['id']} · {_depth_label(c['mastery'])} · {c['kind']} — {c['statement']}")
    out += ["", "### Due for a re-test", *[f"- {i}: {st['concepts'][i]['mastery']['reason']}" for i in st["due"][:12]]]
    qs = [q for q in st["questions"] if q["status"] == "open"]
    if qs:
        out += ["", "### The learner's open questions", *[f"- [{q['id']}] {q['text']}" + (f" (on {q['concept']})" if q["concept"] else "") for q in qs]]
    if st["calibration"]:
        out += ["", "### Calibration notes for this learner", *[f"- {c['note']}" for c in st["calibration"]]]
    return "\n".join(out)


# ── the memory mirror ─────────────────────────────────────────────────

def track_path():
    for path in sorted(glob.glob(os.path.expanduser("~/.claude/projects/*/memory/*.md"))):
        try:
            with open(path, encoding="utf-8") as fh:
                head = fh.read(400)
        except OSError:
            continue
        if re.search(rf"^name:\s*{TRACK_NAME}\s*$", head, re.M):
            return path
    return None


def memory_state(g):
    st = state(g)
    lines = [STATE_HEADING,
             "_Generated from `~/.dotfiles/learning/graph.json` on every write — edit the graph "
             "(viewer Tutor tab, or `learn`), not this section._", ""]
    for tid, t in st["topics"].items():
        p = t["progress"]
        lines.append(f"- **{t['title']}** — {p['held']}/{p['total']} concepts at explain or deeper")
    lines += ["", "**Due for a re-test:**"]
    lines += [f"- {st['concepts'][i]['name']} — {st['concepts'][i]['mastery']['reason']}" for i in st["due"][:10]]
    if len(st["due"]) > 10:
        lines.append(f"- …and {len(st['due']) - 10} more")
    qs = [q for q in st["questions"] if q["status"] == "open"]
    if qs:
        lines += ["", "**Open questions:**", *[f"- {q['text']}" for q in qs]]
    return "\n".join(lines) + "\n"


def write_memory_state(g):
    path = track_path()
    if not path:
        return
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    head = text.split(STATE_HEADING, 1)[0].rstrip("\n")
    new = head + "\n\n" + memory_state(g)
    if new != text:
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(new)
        os.replace(tmp, path)


# ── tutor blocks ──────────────────────────────────────────────────────

BLOCK = re.compile(r"```tutor-(map|evidence|calibration)[ \t]*\r?\n([\s\S]*?)```")


def apply_blocks(g, text, session="", topic=""):
    """Apply a tutor turn's map / evidence / calibration blocks. Returns (topic, applied, errors)."""
    applied, errors = [], []
    for kind, body in BLOCK.findall(text or ""):
        try:
            data = json.loads(body)
        except ValueError as exc:
            errors.append(f"tutor-{kind}: bad JSON ({exc})")
            continue
        try:
            if kind == "map":
                t = dict(data.get("topic") or {})
                t["stages"] = data.get("stages") or []
                topic = upsert_topic(g, t)
                applied.append(f"map {topic}")
            elif kind == "evidence":
                for e in data if isinstance(data, list) else [data]:
                    add_evidence(g, e, session=session, topic=topic)
                    applied.append(f"evidence {e.get('concept')}")
            elif kind == "calibration":
                for note in data if isinstance(data, list) else [data]:
                    add_calibration(g, note)
                applied.append("calibration")
        except (Invalid, AttributeError, TypeError) as exc:
            errors.append(f"tutor-{kind}: {exc}")
    return topic, applied, errors
