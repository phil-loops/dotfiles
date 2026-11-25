"""learning.py — the learner's concept graph: what there is to learn, how deeply it's held, what's due.

One personal graph, not one map per topic. A **concept** is a single idea with a one-line
statement; it `builds_on` the concepts it needs and lists `analogs` — the same idea met in another
topic, which is what lets the tutor go problem-first where an analog is solid. A **topic** (a PR, a
subsystem) is a path through the graph: ordered stages of concept ids.

A **system** (ses-projection, job-queue) is what mastery is measured against: an ordered list of
**standards**, each a can-do sentence ("predict when an undeleted message next becomes visible")
over the concepts it draws on. A concept may serve several standards in several systems. A
standard's own depth comes from evidence rows tagged with it, by the same rule as a concept's; its
coverage is how many of its concepts are shown.

Depth comes only from **evidence** — the learner's own answers (`observed`); a seed row (Claude's guess) or a
chat capture is a hint that shapes the map and never schedules anything:

    level    predict < explain < transfer < critique
    credit   unaided | scaffolded | handed
    outcome  hit | miss

Memory is modeled, not recorded: each level has a **forgetting curve**, recall = 2^(−days since / half-life). An
unaided hit starts or grows the half-life (more when it was harder to retrieve), a miss cuts it, help changes
nothing. A concept's depth is the deepest level probably still held (recall ≥ ½); it is **held** once a spaced
retrieval has grown that level's curve. It comes **due** when recall drops below RETAIN, while a re-test is hard
enough to help, and **fades** below FADED: unknown again, for recall to find. An open miss is due first (a
confident one before any other) until a hit at its level, or until it fades itself.

Evidence rows may carry `confidence` (asked before the reveal), `rung` (predict | invent), on a
miss a `contrast` (the same situation with one variable changed — the re-test *is* the contrast),
and on a transfer `via` (the analog it went through). A concept may hold the learner's own sentence
(`statement_learner`). Per topic the graph derives an **opener** (due neighbors — the session's
first situation, cold), **gaps** (prerequisites never shown unaided) and **transfers** (analogs
held at explain or deeper, where a transfer situation can be posed).

Rows carry a `source`: absent for a tutor session, `chat` for one captured from an ordinary session
that explained a system — same credits, honestly assigned, so what was told counts as handed.

Stored at ~/.dotfiles/learning/graph.json (versioned). Every write regenerates the "Current state"
section of the learner's memory track, so Claude sessions that only read memory still see it.
CLI: scripts/learn.
"""
import datetime
import fcntl
import glob
import json
import math
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
CONFIDENCES = ["low", "medium", "high"]
RUNGS = ["predict", "invent", "recall"]
SOURCES = ["chat"]
SIM_RESULTS = ["green", "red"]
FIRST_HALFLIFE_DAYS = 3
MIN_HALFLIFE_DAYS = 1
MAX_HALFLIFE_DAYS = 365
MISS_FACTOR = 0.25
RETAIN = 0.8
FADED = 0.2
MISS_FADES_DAYS = 60


class Invalid(ValueError):
    pass


def _today():
    """Today, or LEARNING_TODAY when a test pins the clock."""
    return os.environ.get("LEARNING_TODAY") or datetime.date.today().isoformat()


def _empty():
    return {"version": 1, "concepts": {}, "topics": {}, "systems": {}, "standards": {}, "evidence": [],
            "questions": [], "calibration": []}


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
    if _clean(c.get("statement_learner")):
        cur["statement_learner"] = _clean(c["statement_learner"])
        cur["restated"] = _today()
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


def upsert_system(g, s):
    """A system and its standards, in order; each standard's concepts are upserted (and replaced when given)."""
    sid = slug(s.get("id") or s.get("title") or "system")
    cur = g["systems"].setdefault(sid, {"title": "", "summary": "", "standards": [], "created": _today()})
    for key in ("title", "summary"):
        if _clean(s.get(key)):
            cur[key] = _clean(s[key])
    order = list(cur["standards"])
    for st in s.get("standards") or []:
        stid = slug(st.get("id") or st.get("can_do") or "")
        if not stid or stid == "concept":
            raise Invalid("a standard needs an id")
        other = g["standards"].get(stid)
        if other and other["system"] != sid:
            raise Invalid(f"standard {stid} belongs to {other['system']}")
        std = g["standards"].setdefault(stid, {"can_do": "", "system": sid, "concepts": [], "created": _today()})
        if _clean(st.get("can_do")):
            std["can_do"] = _clean(st["can_do"])
        if not std["can_do"]:
            raise Invalid(f"standard {stid} needs a can_do sentence")
        if st.get("concepts") is not None:
            std["concepts"] = _uniq([upsert_concept(g, c) for c in st["concepts"]])
        if stid not in order:
            order.append(stid)
    cur["standards"] = order
    cur["updated"] = _today()
    return sid


def restate(g, cid, text):
    """The learner's own sentence for a concept — written at a summit, shown before the tutor's on a re-test."""
    cid = slug(cid)
    if cid not in g["concepts"]:
        raise Invalid(f"no concept {cid}")
    text = _clean(text)
    if not text:
        raise Invalid("empty restatement")
    g["concepts"][cid]["statement_learner"] = text
    g["concepts"][cid]["restated"] = _today()
    return cid


def _extras(e):
    """Optional evidence fields; absent keys stay absent so old rows and new rows read the same way."""
    confidence, rung, source = e.get("confidence") or "", e.get("rung") or "", e.get("source") or ""
    if confidence not in CONFIDENCES + [""]:
        raise Invalid(f"bad confidence {confidence!r} — one of {CONFIDENCES}")
    if rung not in RUNGS + [""]:
        raise Invalid(f"bad rung {rung!r} — one of {RUNGS}")
    if source not in SOURCES + [""]:
        raise Invalid(f"bad source {source!r} — one of {SOURCES}, or absent for a tutor session")
    out = {"confidence": confidence, "rung": rung, "contrast": _clean(e.get("contrast")),
           "via": slug(e["via"]) if e.get("via") else "", "source": source, "sim": _sim(e.get("sim"))}
    return {k: v for k, v in out.items() if v}


def _sim(sim):
    """The simulator run a rung played (viewer tutor-sim-result): scenario, kernel switches, green or red."""
    if not sim:
        return None
    scenario, kernels, result = sim.get("scenario"), sim.get("kernels") or {}, sim.get("result") or sim.get("outcome")
    if not isinstance(scenario, str) or not scenario:
        raise Invalid("a sim run names its scenario")
    if not isinstance(kernels, dict) or not all(isinstance(v, bool) for v in kernels.values()):
        raise Invalid("sim kernels map each kernel to true or false")
    if result not in SIM_RESULTS:
        raise Invalid(f"bad sim result {result!r} — one of {SIM_RESULTS}")
    out = {"scenario": scenario, "kernels": kernels, "result": result}
    if sim.get("divergence"):
        out["divergence"] = [{"event": str(d["event"]), "kind": str(d["kind"])} for d in sim["divergence"]]
    return out


def add_evidence(g, e, session="", topic=""):
    cid = slug(e["concept"]) if e.get("concept") else ""
    stid = slug(e["standard"]) if e.get("standard") else ""
    if not cid and not stid:
        raise Invalid("evidence needs a concept or a standard")
    if stid and stid not in g["standards"]:
        raise Invalid(f"no standard {stid}")
    level, credit, outcome = e.get("level"), e.get("credit", "unaided"), e.get("outcome", "hit")
    if level not in LEVELS or credit not in CREDITS or outcome not in OUTCOMES:
        raise Invalid(f"bad evidence {level}/{credit}/{outcome} — levels {LEVELS}, credits {CREDITS}, outcomes {OUTCOMES}")
    extras = _extras(e)
    if level == "transfer" and outcome == "hit" and credit == "unaided" and not extras.get("via"):
        raise Invalid("an unaided transfer hit names the analog it transferred through: via")
    if cid and cid not in g["concepts"]:
        upsert_concept(g, {"id": cid, "name": e.get("name")}, topic=topic or None)
    row = {"id": uuid.uuid4().hex[:10], "concept": cid, **({"standard": stid} if stid else {}), "level": level, "credit": credit, "outcome": outcome,
           "note": _clean(e.get("note")), "at": e.get("at") or _today(),
           "topic": slug(topic) if topic else "", "session": session, **extras}
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
            extra = ("confidence", "rung", "contrast", "via", "source")
            for k in extra:
                if k in fields:
                    row.pop(k, None)
            row.update(_extras({k: fields[k] for k in extra if k in fields}))
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


def capture(g, data, session=""):
    """What an ordinary session that explained a system collected, in one write: concepts met (attached to
    a standard when one is named), evidence rows (source chat) and the learner's questions."""
    topic = slug(data["topic"]) if data.get("topic") else ""
    applied = []
    for c in data.get("concepts") or []:
        cid = upsert_concept(g, c, topic=topic or None)
        stid = slug(c["standard"]) if isinstance(c, dict) and c.get("standard") else ""
        if stid:
            if stid not in g["standards"]:
                raise Invalid(f"no standard {stid}")
            g["standards"][stid]["concepts"] = _uniq(g["standards"][stid]["concepts"] + [cid])
        applied.append(f"concept {cid}")
    for e in data.get("evidence") or []:
        add_evidence(g, {**e, "source": "chat"}, session=session, topic=topic)
        applied.append(f"evidence {e.get('standard') or e.get('concept')}")
    for q in data.get("questions") or []:
        q = {"text": q} if isinstance(q, str) else q
        add_question(g, q.get("text"), concept=q.get("concept", ""), topic=topic)
        applied.append("question")
    return applied


def add_calibration(g, note):
    note = _clean(note)
    if note and note not in [c["note"] for c in g["calibration"]]:
        g["calibration"].append({"note": note, "at": _today()})


# ── reads ─────────────────────────────────────────────────────────────

def _days(a, b):
    return (datetime.date.fromisoformat(b) - datetime.date.fromisoformat(a)).days


def observed(row):
    """Whether a row is evidence: the learner answering. A seed (Claude's guess at what they knew) or a chat capture
    (what Claude explained) is a hint that shapes the map, never evidence that moves the curve."""
    return not row.get("source") and not str(row.get("session") or "").startswith("seed")


def mastery(g, cid, today=None):
    """Where the learner's memory of a concept stands now: a forgetting curve per level, from observed rows only."""
    return _mastery([r for r in g["evidence"] if r["concept"] == cid], today)


def standard_mastery(g, stid, today=None):
    """A standard's own depth, by the concept rule over the rows tagged with it."""
    return _mastery([r for r in g["evidence"] if r.get("standard") == stid], today)


def _curve(events, today):
    """One level's forgetting curve from its (date, hit) events, oldest first: (half-life, last date, recall now).

    A first unaided hit starts the half-life at FIRST_HALFLIFE_DAYS. A later hit grows it by how much had been
    forgotten (recall p at that moment): ×(1 + 3(1 − p)), so a same-day repeat adds nothing and a hard-won
    retrieval after a long gap adds most. A miss cuts it to a quarter and leaves nothing held until the next hit."""
    halflife, last, holding = None, None, False
    for day, hit in events:
        if hit:
            if halflife is None:
                halflife = FIRST_HALFLIFE_DAYS
            elif holding:
                p = 2 ** (-_days(last, day) / halflife)
                halflife = min(MAX_HALFLIFE_DAYS, halflife * (1 + 3 * (1 - p)))
            holding = True
        else:
            halflife = max(MIN_HALFLIFE_DAYS, (halflife or FIRST_HALFLIFE_DAYS) * MISS_FACTOR)
            holding = False
        last = day
    recall = 2 ** (-_days(last, today) / halflife) if holding else 0.0
    return halflife, last, recall


def _mastery(rows, today=None):
    """Depth is the deepest level the learner probably still holds (recall ≥ ½); held is the deepest whose curve a
    spaced retrieval has grown. A level comes due as its recall drops below RETAIN, while a re-test is hard enough to
    help, and fades below FADED: unknown again, for recall to find, not a re-test to nag about. A miss stays open
    until a hit at its level or deeper, or until it is MISS_FADES_DAYS old: a misconception fades too. A confident
    miss outranks every other due item (hypercorrection), as long as it is actually re-tested."""
    today = today or _today()
    seen = sorted((r for r in rows if observed(r)), key=lambda r: r["at"])
    curves = {}
    for lvl in range(1, len(LEVELS) + 1):
        events = [(r["at"], r["outcome"] == "hit") for r in seen if r["credit"] == "unaided" and
                  ((r["outcome"] == "hit" and LEVELS.index(r["level"]) + 1 >= lvl) or
                   (r["outcome"] == "miss" and LEVELS.index(r["level"]) + 1 <= lvl))]
        first_hit = next((i for i, (_, hit) in enumerate(events) if hit), None)
        if first_hit is not None:              # a level has a curve once it was shown; a miss before that is only a miss
            curves[lvl] = _curve(events[first_hit:], today)
    depth = max((l for l, c in curves.items() if c[2] >= 0.5), default=0)
    held = max((l for l, c in curves.items() if c[2] >= 0.5 and c[0] >= 2 * FIRST_HALFLIFE_DAYS), default=0)
    assisted = max([LEVELS.index(r["level"]) + 1 for r in seen if r["outcome"] == "hit" and r["credit"] != "unaided"
                    and _days(r["at"], today) <= MISS_FADES_DAYS] + [depth])
    open_miss = None
    for r in seen:
        if r["outcome"] == "miss":
            open_miss = r
        elif open_miss and r["credit"] == "unaided" and LEVELS.index(r["level"]) >= LEVELS.index(open_miss["level"]):
            open_miss = None
    if open_miss and _days(open_miss["at"], today) > MISS_FADES_DAYS:
        open_miss = None
    shown = max(curves, default=0)                     # the deepest level ever shown: the one whose fading matters
    halflife, last, recall = curves.get(shown, (None, "", 0.0))
    if shown and recall == 0.0 and not open_miss:      # its curve ends in a faded miss: the level below still counts
        shown = max((l for l, c in curves.items() if c[2] > 0), default=0)
        halflife, last, recall = curves.get(shown, (None, "", 0.0))
    due_after = halflife * math.log2(1 / RETAIN) if halflife else 0
    faded = bool(seen) and not open_miss and recall < FADED and assisted == 0
    if open_miss:
        due, reason, overdue = True, f"missed: {open_miss['note'] or open_miss['level']}", _days(open_miss["at"], today)
    elif depth == 0 and assisted:
        due, reason, overdue = True, "only shown with help", 0
    elif shown and FADED <= recall < RETAIN:
        age = _days(last, today)
        due, reason = True, f"about {round(recall * 100)}% likely still held at {LEVELS[shown - 1]}, last shown {age} days ago"
        overdue = max(0, round(age - due_after))
    else:
        due, reason, overdue = False, "", 0
    return {"depth": depth, "assisted": assisted, "level": LEVELS[depth - 1] if depth else "",
            "held": held, "held_level": LEVELS[held - 1] if held else "",
            "evidence": len(seen), "hints": len(rows) - len(seen), "last": seen[-1]["at"] if seen else "",
            "known": bool(depth or open_miss or assisted), "faded": faded,
            "recall": round(recall, 3), "halflife": round(halflife, 1) if halflife else 0,
            "due": due, "reason": reason,
            "open_miss": (open_miss["note"] or f"missed at {open_miss['level']}") if open_miss else "",
            "miss_confidence": (open_miss or {}).get("confidence", ""),
            "contrast": (open_miss or {}).get("contrast", ""),
            "misses": sum(1 for r in seen if r["outcome"] == "miss"),
            "overconfident": sum(1 for r in seen if r["outcome"] == "miss" and r.get("confidence") == "high"),
            "shown_level": LEVELS[shown - 1] if shown else "", "spacing": round(due_after), "overdue": overdue}


def _priority(m):
    # confident misses, then any open miss, then help-only, then once-only, then the most overdue
    if m["open_miss"]:
        return (0, 0 if m["miss_confidence"] == "high" else 1)
    if m["depth"] == 0:
        return (1, 0)
    if not m["held"]:
        return (2, 0)
    return (3, -1)


def state(g, today=None):
    today = today or _today()
    concepts = {cid: {**c, "id": cid, "mastery": mastery(g, cid, today)} for cid, c in g["concepts"].items()}
    for c in concepts.values():
        c["built_on_by"] = sorted(o for o, oc in g["concepts"].items() if c["id"] in oc["builds_on"])
        # a prerequisite never shown unaided — or named but never defined — blocks this concept
        c["blocked_by"] = [b for b in c["builds_on"] if b not in concepts or concepts[b]["mastery"]["depth"] == 0]
    due = sorted((c for c in concepts.values() if c["mastery"]["due"]),
                 key=lambda c: (_priority(c["mastery"]), c["mastery"]["last"]))
    topics = {}
    for tid, t in g["topics"].items():
        ids = [i for st in t["stages"] for i in st["concepts"]]
        ms = [concepts[i]["mastery"] for i in ids if i in concepts]
        topics[tid] = {**t, "id": tid, "progress": {
            "held": sum(1 for m in ms if m["held"] >= 2),
            "shown": sum(1 for m in ms if m["depth"] >= 2),
            "total": len(ids)}}
    standards = {}
    for stid, s in g["standards"].items():
        ms = [concepts[i]["mastery"] for i in s["concepts"] if i in concepts]
        standards[stid] = {**s, "id": stid, "mastery": standard_mastery(g, stid, today), "coverage": {
            "held": sum(1 for m in ms if m["held"]),
            "shown": sum(1 for m in ms if m["depth"]),
            "total": len(s["concepts"])}}
    systems = {}
    for sid, s in g["systems"].items():
        ms = [standards[i]["mastery"] for i in s["standards"] if i in standards]
        systems[sid] = {**s, "id": sid, "progress": {
            "held": sum(1 for m in ms if m["held"]),
            "met": sum(1 for m in ms if m["depth"]),
            "total": len(s["standards"])}}
    standards_due = sorted((s for s in standards.values() if s["mastery"]["due"]),
                           key=lambda s: (_priority(s["mastery"]), s["mastery"]["last"]))
    return {"concepts": concepts, "topics": topics, "due": [c["id"] for c in due],
            "systems": systems, "standards": standards, "standards_due": [s["id"] for s in standards_due],
            "questions": g["questions"], "calibration": g["calibration"], "evidence": g["evidence"],
            "levels": LEVELS, "credits": CREDITS, "confidences": CONFIDENCES, "rungs": RUNGS, "sources": SOURCES,
            "today": today}


def _topic_ids(g, topic):
    t = g["topics"].get(topic) or {"stages": []}
    return [i for st in t["stages"] for i in st["concepts"]]


def opener(g, topic, today=None):
    """Due concepts that neighbor the topic (an analog or a prerequisite of one of its concepts) —
    the first situation of a session is one of these, cold: spaced retrieval and the analog check
    in one unaided row, before any framing exists."""
    st = state(g, today)
    ids = set(_topic_ids(g, topic))
    near = set()
    for i in ids:
        c = st["concepts"].get(i)
        if c:
            near.update(c["analogs"])
            near.update(c["builds_on"])
    near -= ids
    return [{"id": i, "reason": st["concepts"][i]["mastery"]["reason"],
             "neighbor_of": sorted(j for j in ids if i in st["concepts"][j]["analogs"] + st["concepts"][j]["builds_on"])}
            for i in st["due"] if i in near]


def transfers(g, topic, today=None):
    """Transfer situations the graph can already supply: for each concept of the topic, an analog
    held at explain or deeper — pose this concept's situation in the analog's setting. A transfer
    row is written only this way."""
    st = state(g, today)
    out = []
    for i in _topic_ids(g, topic):
        c = st["concepts"].get(i)
        if not c:
            continue
        for a in c["analogs"]:
            ac = st["concepts"].get(a)
            if ac and ac["mastery"]["depth"] >= 2:
                out.append({"concept": i, "via": a, "setting": ac["topics"][0] if ac["topics"] else ""})
    return out


def gaps(g, topic, today=None):
    """Prerequisites of the topic's concepts never shown unaided, in stage order."""
    st = state(g, today)
    seen, out = set(), []
    for i in _topic_ids(g, topic):
        for b in st["concepts"].get(i, {}).get("blocked_by", []):
            if b not in seen:
                seen.add(b)
                out.append({"concept": b, "blocks": i})
    return out


def retest(g, today=None, system=None, everything=False):
    """The one re-test worth a minute right now: the top due concept not already tested today — within the
    given system, else within any system (mastery is measured there; a concept on no system's standards
    waits for --all), with what a single situation needs — the open miss and its contrast, the
    learner's own sentence, code to build it from, held analogs to pose it through."""
    st = state(g, today)
    tested_today = {r["concept"] for r in g["evidence"] if r["at"] == st["today"]}
    scope = None
    if system:
        if system not in st["systems"]:
            raise Invalid(f"no system {system}")
        scope = {i for stid in st["systems"][system]["standards"] for i in st["standards"].get(stid, {}).get("concepts", [])}
    elif st["systems"] and not everything:
        scope = {i for s in st["standards"].values() for i in s["concepts"]}
    due = [i for i in st["due"] if i not in tested_today and (scope is None or i in scope)]
    if not due:
        return {"due": 0}
    c = st["concepts"][due[0]]
    m = c["mastery"]
    rows = [r for r in g["evidence"] if r["concept"] == c["id"]]
    return {"due": len(due), "concept": c["id"], "name": c["name"], "kind": c["kind"], "statement": c["statement"],
            "statement_learner": c.get("statement_learner", ""), "depth": _depth_label(m), "level": m["level"],
            "reason": m["reason"], "overdue": m["overdue"], "open_miss": m["open_miss"],
            "miss_confidence": m["miss_confidence"], "contrast": m["contrast"], "code": c["code"],
            "held_analogs": [a for a in c["analogs"] if st["concepts"].get(a, {}).get("mastery", {}).get("depth", 0) >= 2],
            "standards": [{"id": sid, "system": s["system"], "can_do": s["can_do"]}
                          for sid, s in st["standards"].items() if c["id"] in s["concepts"]],
            "history": [{k: r[k] for k in ("at", "level", "credit", "outcome", "note")} for r in rows[-4:]]}


# ── the session policy ────────────────────────────────────────────────

FORMS = ["recall", "worked", "predict", "contrast", "explain", "transfer", "critique", "card", "done"]
SESSION_STEPS = 8
INTERLEAVE_EVERY = 4
CONTRASTS_PER_SESSION = 2
LEVEL_FORM = {"predict": "predict", "explain": "explain", "transfer": "transfer", "critique": "critique"}


def scope_ids(g, topic=None, system=None, concept=None):
    """The concepts a session works over, in teaching order: a topic's stages, a system's standards, or one concept."""
    if concept:
        if concept not in g["concepts"]:
            raise Invalid(f"no concept {concept}")
        return [concept]
    if topic:
        if topic not in g["topics"]:
            raise Invalid(f"no topic {topic}")
        return _uniq(_topic_ids(g, topic))
    if system:
        if system not in g["systems"]:
            raise Invalid(f"no system {system}")
        return _uniq([i for stid in g["systems"][system]["standards"] for i in g["standards"].get(stid, {}).get("concepts", [])])
    raise Invalid("a session works over a topic, a system or a concept")


def _asked(asked):
    return [{"concept": slug(a.get("concept") or ""), "form": a.get("form") or "", "level": a.get("level") or ""}
            for a in asked or []]


def next_step(g, topic=None, system=None, session="", asked=(), today=None, concept=None):
    """The session's next step, decided from evidence rather than by the tutor's feel.

    `asked` is what the session has already posed, in order ({concept, form, level}); `session` tags this
    session's evidence rows. In order of precedence:
      card    after SESSION_STEPS steps, or when nothing is left: the learner writes the sentence they'd keep
      recall  a topic that's mostly unknown now (never shown, or faded) opens with free recall, which sorts what's known from what's not
      contrast a miss from this session comes back as the same situation with one thing changed, one step later;
              an older open miss on the topic comes before anything new
      re-test every INTERLEAVE_EVERY steps (and first, when there's no recall) a due neighbor of the topic
      due     a concept of the topic that's due is re-tested at the level it's held or was missed at
      edge    the first concept in teaching order whose prerequisites are shown, one level above its depth —
              two levels after a run of unaided hits, a prerequisite first when one was never shown, and a
              worked example before a cold prediction on a concept not known now
    A one-concept session (a re-test) is one step, and a contrast after it when that step missed; no card.
    """
    asked = _asked(asked)
    st = state(g, today)
    ids = [i for i in scope_ids(g, topic, system, concept) if i in st["concepts"]]
    if not ids:
        raise Invalid("the topic has no concepts yet")
    concepts = st["concepts"]
    n = len(asked)
    rows = [r for r in g["evidence"] if session and r.get("session") == session]
    paced = [r for r in rows if r.get("rung") != "recall"]
    stretch = len(paced) >= 4 and all(r["outcome"] == "hit" and r["credit"] == "unaided" for r in paced[-4:])
    support = bool(paced) and paced[-1]["outcome"] == "miss"
    last = asked[-1]["concept"] if asked else ""
    posed = {(a["concept"], a["level"]) for a in asked}

    def out(form, cid="", level="", why="", **extra):
        c = concepts.get(cid) or {}
        return {"step": n + 1, "form": form, "concept": cid, "name": c.get("name", ""), "statement": c.get("statement", ""),
                "statement_learner": c.get("statement_learner", ""), "level": level, "why": why,
                "stations": _stations(g, st, topic, cid), **extra}

    def retest_level(cid):
        m = concepts[cid]["mastery"]
        if m["open_miss"]:
            return next(r["level"] for r in reversed(g["evidence"]) if r["concept"] == cid and r["outcome"] == "miss")
        return m["shown_level"] or LEVELS[max(m["depth"], m["assisted"], 1) - 1]

    def retest(cid, why):
        m = concepts[cid]["mastery"]
        level = retest_level(cid)
        if m["open_miss"]:
            return out("contrast", cid, level, why, contrast=m["contrast"], misconception=m["open_miss"])
        return out(LEVEL_FORM[level], cid, level, why)

    if concept:
        if n == 0:
            m = concepts[concept]["mastery"]
            if m["due"] or m["known"]:
                return retest(concept, f"re-test: {m['reason'] or 'not due, asked for'}")
            return out("worked", concept, "predict", "new: watch one run, then predict a variant")
        missed = [r for r in rows if r["concept"] == concept and r["outcome"] == "miss"]
        contrasts = sum(1 for a in asked if a["form"] == "contrast")
        if missed and concepts[concept]["mastery"]["open_miss"] and contrasts < len(missed) and n < 3:
            return out("contrast", concept, retest_level(concept), "missed: the same situation with one thing changed",
                       contrast=concepts[concept]["mastery"]["contrast"], misconception=concepts[concept]["mastery"]["open_miss"])
        return out("done", why="a re-test is one situation")

    if any(a["form"] == "card" for a in asked):
        return out("done", why="the session closed on its card")
    if n >= SESSION_STEPS:
        return out("card", _focus(rows, ids), why=f"{SESSION_STEPS} steps is a session; close while it's fresh")
    unmapped = [i for i in ids if not concepts[i]["mastery"]["known"]]
    if n == 0 and topic and len(unmapped) * 2 > len(ids):
        return out("recall", why="most of this topic isn't known now (never shown, or faded): say everything you know, and the gaps show")

    # a concept whose latest row this session is a miss is owed a contrast (at most CONTRASTS_PER_SESSION), one step later
    deferred = None
    for cid in _uniq(r["concept"] for r in rows if r["outcome"] == "miss"):
        m = concepts.get(cid, {}).get("mastery")
        latest = [r for r in rows if r["concept"] == cid][-1]
        posed_contrasts = sum(1 for a in asked if a["concept"] == cid and a["form"] == "contrast")
        if not (m and m["open_miss"] and latest["outcome"] == "miss" and posed_contrasts < CONTRASTS_PER_SESSION):
            continue
        owed = out("contrast", cid, retest_level(cid), "missed this session: the same situation with one thing changed",
                   contrast=m["contrast"], misconception=m["open_miss"])
        if cid != last or n >= SESSION_STEPS - 1:
            return owed
        deferred = deferred or owed

    asked_ids = {a["concept"] for a in asked}
    for cid in st["due"]:
        if cid in ids and cid not in asked_ids and concepts[cid]["mastery"]["open_miss"]:
            return retest(cid, f"an open miss on this topic: {concepts[cid]['mastery']['open_miss']}")

    if topic and (n % INTERLEAVE_EVERY == INTERLEAVE_EVERY - 1 or (n == 0)):
        for o in opener(g, topic, today):
            if not any(a["concept"] == o["id"] for a in asked):
                return retest(o["id"], f"due, and a neighbor of this topic ({o['reason']}): mixing it in keeps it alive")

    for cid in st["due"]:
        if cid in ids and cid not in asked_ids:
            return retest(cid, f"due: {concepts[cid]['mastery']['reason']}")

    for cid in ids:
        c = concepts[cid]
        m = c["mastery"]
        if m["open_miss"]:
            continue   # a concept isn't pushed further while a miss on it stands; its contrast comes first
        blocker = next((b for b in c["blocked_by"] if (b, "predict") not in posed), None)
        if c["blocked_by"]:
            if blocker and concepts.get(blocker, {}).get("mastery", {}).get("open_miss"):
                return retest(blocker, f"{c['name']} builds on it, and a miss on it stands")
            if blocker:
                form = "worked" if not concepts.get(blocker, {}).get("mastery", {}).get("known") else "predict"
                return out(form, blocker, "predict", f"{c['name']} builds on it, and it was never shown unaided")
            continue
        target = m["depth"] + (2 if stretch and m["depth"] + 2 <= len(LEVELS) else 1)
        if target > len(LEVELS):
            continue
        level = LEVELS[target - 1]
        via = ""
        if level == "transfer":
            via = next((a for a in c["analogs"] if concepts.get(a, {}).get("mastery", {}).get("depth", 0) >= 2), "")
            if not via:
                level = "critique"
        if (cid, level) in posed:
            continue
        if level == "predict" and not m["known"] and not stretch:
            form, why = "worked", "new: watch one run, then predict a variant"
        elif level == "predict" and support:
            form, why = "worked", "after a miss, a worked run before the next cold prediction"
        else:
            form = LEVEL_FORM[level]
            why = (f"shown at {m['level']}; next is {level}" if m["depth"] else f"next is {level}") + \
                  (" (skipping a level after a run of hits)" if target == m["depth"] + 2 else "")
        return out(form, cid, level, why, **({"via": via} if via else {}))

    if deferred:
        return deferred
    return out("card", _focus(rows, ids), why="nothing on this topic is left to push today")


def _focus(rows, ids):
    """The concept this session worked most: the card's subject."""
    counts = {}
    for r in rows:
        if r["concept"] in ids:
            counts[r["concept"]] = counts.get(r["concept"], 0) + 1
    return max(counts, key=counts.get) if counts else (ids[0] if ids else "")


def stations(g, topic, current="", today=None):
    """A topic's stages as stations, with `current` (the concept on screen) marking the current one."""
    if topic not in g["topics"]:
        raise Invalid(f"no topic {topic}")
    return _stations(g, state(g, today), topic, slug(current) if current else "")


def _stations(g, st, topic, current):
    """A topic's stages as the session's stations: done once every concept is shown at explain or deeper."""
    if not topic:
        return []
    out = []
    for s in g["topics"][topic]["stages"]:
        depths = [st["concepts"][i]["mastery"]["depth"] for i in s["concepts"] if i in st["concepts"]]
        state_ = ("current" if current in s["concepts"] else
                  "done" if depths and min(depths) >= 2 else "todo")
        out.append({"name": s["name"], "state": state_})
    return out


def branches(g, step, topic=None, system=None, session="", asked=(), today=None, concept=None):
    """What `next_step` will say once the open step lands as a hit, and as a miss — so the next step can be
    drafted while the learner is still reading this one."""
    import copy
    out = {}
    for outcome in OUTCOMES:
        h = copy.deepcopy(g)
        h["evidence"].append({"id": "assumed", "concept": slug(step["concept"]), "level": step.get("level") or "predict",
                              "credit": "unaided", "outcome": outcome, "note": step.get("misconception") or "",
                              "at": today or _today(), "topic": topic or "", "session": session or "assumed"})
        out[outcome] = next_step(h, topic, system, session or "assumed", list(asked) + [step], today, concept)
    return out


def _depth_label(m):
    if m["depth"]:
        s = m["level"] + (" held" if m["held"] >= m["depth"] else
                          f" once (held at {m['held_level']})" if m["held"] else " once")
        if m["assisted"] > m["depth"]:
            s += f" (+{LEVELS[m['assisted'] - 1]} with help)"
        if m["overconfident"]:
            s += f" · overconfident miss ×{m['overconfident']}"
        return s
    if m["assisted"]:
        return f"{LEVELS[m['assisted'] - 1]} with help only"
    return "faded" if m["faded"] else "not yet shown"


def _concept_line(i, c):
    m = c["mastery"]
    an = ", ".join(c["analogs"])
    s = f"- {i} · {_depth_label(m)} · {c['kind']} — {c['statement']}"
    if c.get("statement_learner"):
        s += f" · in their words: “{c['statement_learner']}”"
    if an:
        s += f" · analogs: {an}"
    if c["blocked_by"]:
        s += f" · BLOCKED BY (never shown): {', '.join(c['blocked_by'])}"
    if m["open_miss"]:
        s += f" · OPEN MISS{' (high confidence)' if m['miss_confidence'] == 'high' else ''}: {m['open_miss']}"
        if m["contrast"]:
            s += f" → re-test with the contrast: {m['contrast']}"
    return s


def _standard_label(s):
    m = s["mastery"]
    label = _depth_label(m) if m["evidence"] else "not yet assessed"
    if m["open_miss"]:
        label += f" · OPEN MISS: {m['open_miss']}"
    cov = s["coverage"]
    return f"{label} · concepts {cov['held']} held / {cov['shown']} shown / {cov['total']}"


def system_digest(st, sid):
    s = st["systems"][sid]
    p = s["progress"]
    out = [f"### Active system: {s['title']} [{sid}] — {p['held']} held / {p['met']} met / {p['total']} standards",
           s["summary"], ""]
    for stid in s["standards"]:
        std = st["standards"].get(stid)
        if not std:
            continue
        out.append(f"- **{stid}** — {std['can_do']} · {_standard_label(std)}")
        for i in std["concepts"]:
            c = st["concepts"].get(i)
            if c:
                out.append("  " + _concept_line(i, c))
    due = [i for i in st["standards_due"] if st["standards"][i]["system"] == sid]
    if due:
        out += ["", "**Standards due** (aim the next situation here):",
                *[f"- {i}: {st['standards'][i]['mastery']['reason']}" for i in due]]
    unassessed = [i for i in s["standards"] if i in st["standards"] and not st["standards"][i]["mastery"]["evidence"]]
    if unassessed:
        out += ["", "**Never assessed** (no standard-tagged row yet): " + ", ".join(unassessed)]
    return out + [""]


def digest(g, topic=None, today=None, system=None):
    """Compact text for a tutor's prompt: the whole graph at a glance, the active topic or system in full."""
    st = state(g, today)
    out = ["## The learner's concept graph (~/.dotfiles/learning/graph.json)",
           "Depth = deepest level probably still held UNAIDED (a forgetting curve per level, moved only by the "
           "learner's answers): predict < explain < transfer < critique. “held” = a spaced retrieval grew it; "
           "“once” = not yet retention; “faded” = shown before, likely forgotten: show it again, don't quiz it.", ""]
    if st["systems"]:
        out.append("### Systems (mastery target: each standard held)")
        out += [f"- {s['title']} [{sid}] — {s['progress']['held']} held / {s['progress']['met']} met / "
                f"{s['progress']['total']} standards" for sid, s in st["systems"].items()]
        out.append("")
    if system and system in st["systems"]:
        out += system_digest(st, system)
    if topic and topic in st["topics"]:
        t = st["topics"][topic]
        out.append(f"### Active topic: {t['title']} [{topic}] — {t['source']}")
        for s in t["stages"]:
            out.append(f"- stage **{s['name']}**: " + ", ".join(
                f"{i} ({_depth_label(st['concepts'][i]['mastery'])})" for i in s["concepts"] if i in st["concepts"]))
        op = opener(g, topic, today)
        if op:
            out += ["", "**Open with one of these, cold** (due, and a neighbor of this topic — the first situation of the session):",
                    *[f"- {o['id']} — {o['reason']} · neighbor of {', '.join(o['neighbor_of'])}" for o in op[:4]]]
        gp = gaps(g, topic, today)
        if gp:
            out += ["", "**Prerequisite gaps** (never shown unaided; teach or re-test before the concept that needs it):",
                    *[f"- {x['concept']} → needed by {x['blocks']}" for x in gp]]
        tr = transfers(g, topic, today)
        if tr:
            out += ["", "**Transfer situations available** (pose the concept in the analog's setting; the only way a transfer row is earned):",
                    *[f"- {x['concept']} via {x['via']}" + (f" ({x['setting']})" if x["setting"] else "") for x in tr]]
        out.append("")
    out.append("### All concepts (id · depth · kind — statement · analogs)")
    for tid, t in st["topics"].items():
        out.append(f"**{t['title']}** [{tid}] — {t['progress']['held']} held / {t['progress']['shown']} shown / {t['progress']['total']}")
        for s in t["stages"]:
            for i in s["concepts"]:
                c = st["concepts"].get(i)
                if c:
                    out.append(_concept_line(i, c))
    loose = [c for c in st["concepts"].values() if not c["topics"]]
    if loose:
        out.append("**Not on any topic yet**")
    for c in loose:
        out.append(_concept_line(c["id"], c))
    out += ["", "### Due for a re-test (confident misses first, then misses, help-only, once-only, overdue)",
            *[f"- {i}: {st['concepts'][i]['mastery']['reason']} ({st['concepts'][i]['mastery']['overdue']} days overdue)"
              for i in st["due"][:12]]]
    qs = [q for q in st["questions"] if q["status"] == "open"]
    if qs:
        out += ["", "### The learner's open questions", *[f"- [{q['id']}] {q['text']}" + (f" (on {q['concept']})" if q["concept"] else "") for q in qs]]
    if st["calibration"]:
        out += ["", "### Calibration notes for this learner", *[f"- {c['note']}" for c in st["calibration"]]]
    return "\n".join(out)


def commit(path=None, message="learning: session evidence"):
    """Commits the graph file alone (a pathspec commit) when it changed, so a session's evidence is kept without
    anyone tending the file. Returns what happened; a graph outside a git checkout is left alone."""
    import subprocess
    path = os.path.realpath(path or GRAPH)
    repo = subprocess.run(["git", "-C", os.path.dirname(path), "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if repo.returncode != 0:
        return "not in a git checkout"
    top = repo.stdout.strip()
    rel = os.path.relpath(path, top)
    if not subprocess.run(["git", "-C", top, "status", "--porcelain", "--", rel], capture_output=True, text=True).stdout.strip():
        return "unchanged"
    done = subprocess.run(["git", "-C", top, "commit", "--only", "-q", "-m", message, "--", rel], capture_output=True, text=True)
    if done.returncode != 0:
        raise Invalid(f"git commit failed: {(done.stderr or done.stdout).strip()}")
    return "committed"


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
    for sid, s in st["systems"].items():
        p = s["progress"]
        lines.append(f"- system **{s['title']}** — {p['held']} held, {p['met']} met, of {p['total']} standards "
                     f"(`learn state --system {sid}`)")
    for tid, t in st["topics"].items():
        p = t["progress"]
        lines.append(f"- **{t['title']}** — {p['held']} held, {p['shown']} shown once, of {p['total']} (at explain or deeper)")
    lines += ["", "**Due for a re-test:**"]
    lines += [f"- {st['concepts'][i]['name']} — {st['concepts'][i]['mastery']['reason']}" for i in st["due"][:10]]
    if len(st["due"]) > 10:
        lines.append(f"- …and {len(st['due']) - 10} more")
    qs = [q for q in st["questions"] if q["status"] == "open"]
    if qs:
        lines += ["", "**Open questions:**", *[f"- {q['text']}" for q in qs]]
    return "\n".join(lines) + "\n"


def write_memory_state(g):
    if os.environ.get("LEARNING_MEMORY") == "0":
        return
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

BLOCK = re.compile(r"```tutor-(map|evidence|calibration|restate|question)[ \t]*\r?\n([\s\S]*?)```")


def apply_blocks(g, text, session="", topic=""):
    """Apply a tutor turn's map / evidence / calibration / restate / question blocks. Returns (topic, applied, errors)."""
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
            elif kind == "restate":
                for r in data if isinstance(data, list) else [data]:
                    restate(g, r.get("concept"), r.get("text"))
                    applied.append(f"restate {slug(r.get('concept'))}")
            elif kind == "question":
                for q in data if isinstance(data, list) else [data]:
                    if isinstance(q, str):
                        q = {"text": q}
                    add_question(g, q.get("text"), concept=q.get("concept", ""), topic=topic)
                    applied.append("question")
        except (Invalid, AttributeError, TypeError) as exc:
            errors.append(f"tutor-{kind}: {exc}")
    return topic, applied, errors
