"""The viewer's own feature tracker: ~/.dotfiles/canopy/todo/<id>.md, one item per file.

An item is TOML frontmatter between `+++` lines, then a markdown body (context; `/next` writes a
`## Next steps` section). Fields:
  title      verb-first, one line
  kind       build | fix | decide | look        (decide = needs Phil; look = a question to answer)
  state      open | doing | waiting | done | dropped
  area       which part of the viewer (review, forests, keys, server, gen, ...)
  size       S | M | L
  why        what it's worth, one line
  waiting    what it waits on, for state "waiting"
  blocked_by ids of items that must land first
  links      wiki pages, memory files, commits, artifacts
  rank       position in the open queue, set by /next (lower first; unset = unranked)
  created / updated   dates
One file per item so concurrent sessions never write the same file; git is the history.
"""
import datetime
import os
import re
import tomllib

DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "canopy", "todo")
KINDS = ("build", "fix", "decide", "look")
STATES = ("open", "doing", "waiting", "done", "dropped")
SIZES = ("S", "M", "L")
FIELDS = ("title", "kind", "state", "area", "size", "why", "waiting", "blocked_by", "links", "rank", "created", "updated")


def slug(title):
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", title.lower())).strip("-")[:60].rstrip("-")


def path(item_id):
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", item_id or ""):
        raise ValueError(f"not an item id: {item_id!r}")
    return os.path.join(DIR, f"{item_id}.md")


def parse(text):
    m = re.match(r"\+\+\+\n(.*?)\n\+\+\+\n?(.*)", text, re.S)
    if not m:
        raise ValueError("no +++ frontmatter")
    meta = tomllib.loads(m.group(1))
    for k in ("created", "updated"):
        if isinstance(meta.get(k), datetime.date):
            meta[k] = meta[k].isoformat()
    return meta, m.group(2).strip("\n")


def check(meta):
    """What's wrong with an item's fields, as lines; empty when it's sound."""
    bad = []
    if not meta.get("title"):
        bad.append("no title")
    for k, allowed in (("kind", KINDS), ("state", STATES), ("size", SIZES)):
        if meta.get(k) not in allowed:
            bad.append(f"{k} {meta.get(k)!r} is not one of {', '.join(allowed)}")
    if meta.get("state") == "waiting" and not meta.get("waiting"):
        bad.append("waiting on nothing — say what")
    for k in meta:
        if k not in FIELDS:
            bad.append(f"unknown field {k}")
    return bad


def _toml(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, list):
        return "[" + ", ".join(_toml(x) for x in v) + "]"
    return '"' + str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'


def render(meta, body):
    lines = [f"{k} = {_toml(meta[k])}" for k in FIELDS if meta.get(k) not in (None, "", [])]
    return "+++\n" + "\n".join(lines) + "\n+++\n" + (f"\n{body.strip()}\n" if body.strip() else "")


def read(item_id):
    with open(path(item_id)) as f:
        meta, body = parse(f.read())
    return {"id": item_id, **meta, "body": body}


def write(item_id, meta, body):
    bad = check(meta)
    if bad:
        raise ValueError(f"{item_id}: " + "; ".join(bad))
    os.makedirs(DIR, exist_ok=True)
    tmp = path(item_id) + ".tmp"
    with open(tmp, "w") as f:
        f.write(render(meta, body))
    os.replace(tmp, path(item_id))


def ids():
    try:
        return sorted(n[:-3] for n in os.listdir(DIR) if n.endswith(".md"))
    except FileNotFoundError:
        return []


def fingerprint():
    """Moves when any item file is added, removed or saved — a stat per file, no reads."""
    out = []
    for i in ids():
        try:
            st = os.stat(path(i))
            out.append((i, st.st_mtime_ns, st.st_size))
        except OSError:
            pass
    return tuple(out)


def all_items():
    """Every item; one that won't parse comes back with state "broken" and the reason, never dropped."""
    out = []
    for i in ids():
        try:
            item = read(i)
            bad = check({k: v for k, v in item.items() if k not in ("id", "body")})
            if bad:
                item["problems"] = bad
            out.append(item)
        except (OSError, ValueError, tomllib.TOMLDecodeError) as e:
            out.append({"id": i, "title": i, "state": "broken", "problems": [str(e)], "body": ""})
    return out


def today():
    return datetime.date.today().isoformat()


def update(item_id, **fields):
    item = read(item_id)
    body = fields.pop("body", item.pop("body"))
    item.pop("id")
    item.pop("problems", None)
    item.update({k: v for k, v in fields.items()})
    item = {k: v for k, v in item.items() if v not in (None, "", [])}
    item["updated"] = today()
    write(item_id, item, body)
    return read(item_id)


def entities():
    """The `todo` domain of /state: {todo: {id: item}}."""
    return {"todo": {it["id"]: it for it in all_items()}}


PAGE_FIELDS = {"state": STATES, "rank": None}


def post(req, raw):
    """POST /todo-item {id, set: {state?, rank?}} or {ranks: {id: n}} — the tracker page's moves;
    anything richer is canopy-todo's (or /next's) job."""
    import json
    from . import state
    try:
        d = json.loads(raw or "{}")
        if "ranks" in d:
            ranks = d["ranks"] or {}
            if not all(v is None or (isinstance(v, int) and v > 0) for v in ranks.values()):
                raise ValueError("ranks are positive integers (or null to unrank)")
            for i in ranks:
                read(i)
            for i, r in ranks.items():
                update(i, rank=r)
            state.poke()
            return req._send(200, json.dumps({"ok": True}))
        fields = d.get("set") or {}
        for k, v in fields.items():
            if k not in PAGE_FIELDS or (PAGE_FIELDS[k] and v not in PAGE_FIELDS[k]) or (k == "rank" and v is not None and not isinstance(v, int)):
                raise ValueError(f"can't set {k}={v!r} here")
        if fields.get("state") in ("done", "dropped"):
            fields["rank"] = None
        item = update(d.get("id", ""), **fields)
    except (OSError, ValueError, tomllib.TOMLDecodeError) as e:
        return req._send(400, json.dumps({"ok": False, "error": str(e)}))
    state.poke()
    req._send(200, json.dumps({"ok": True, "item": item}))
