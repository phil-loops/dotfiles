"""The tracker: ~/.dotfiles/canopy/todo/<id>.md, one item per file. Items without a project are
the viewer's own feature list; items with one are that forest's todo list.

An item is TOML frontmatter between `+++` lines, then a markdown body (context; `/next` writes a
`## Next steps` section). Fields:
  title      verb-first, one line
  kind       build | fix | decide | look        (decide = needs Phil; look = a question to answer)
  state      open | doing | waiting | done | dropped
  area       which part of the viewer (review, forests, keys, server, gen, ...), or of the project
  project    "<repo>:<stack-project>" for a forest's own list (the viewer's project id); empty = the viewer
  size       S | M | L
  why        what it's worth, one line
  waiting    what it waits on, for state "waiting"
  blocked_by ids of items that must land first
  links      wiki pages, memory files, commits, artifacts
  rank       position in the open queue, set by /next (lower first; unset = unranked)
  solved_by  on a forest's list, the branch that solves the item (a ticket's ask → the PR covering it)
  incarnation  minted once when the record is created and never changed: the work journal links to an
             item by id and incarnation, so a deleted item recreated under the same id inherits nothing
  created / updated   dates
One file per item so concurrent sessions never write the same file; git is the history.
Every read-modify-write (`update`) holds one lock over the directory, so two writers of the same
item serialize: progress written from an old read can't erase an input recorded in between.
"""
import contextlib
import datetime
import fcntl
import hashlib
import os
import re
import tomllib

DIR = os.environ.get("CANOPY_TODO_DIR") or os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "canopy", "todo")
KINDS = ("build", "fix", "decide", "look")
STATES = ("open", "doing", "waiting", "done", "dropped")
SIZES = ("S", "M", "L")
FIELDS = ("title", "kind", "state", "owner", "area", "project", "size", "why", "waiting", "blocked_by", "links", "rank", "solved_by", "incarnation", "created", "updated")


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
    if meta.get("project") and not re.fullmatch(r"[^:\s]+:[^:\s]+", meta["project"]):
        bad.append(f"project {meta['project']!r} is not <repo>:<stack-project>")
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


class Stale(ValueError):
    """The item changed since the version the caller read; nothing was written."""


@contextlib.contextmanager
def _locked():
    """One writer at a time across processes: flock on the directory itself, so no lock file
    lands in the tracked tree."""
    os.makedirs(DIR, exist_ok=True)
    fd = os.open(DIR, os.O_RDONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def version(item_id):
    """A content digest of the item as stored, for `update(..., expect=)`."""
    with open(path(item_id), "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()[:16]


def update(item_id, edit=None, expect=None, **fields):
    """Read-modify-write under the lock. `edit(item) -> fields` computes the change from the
    item as it is now (use it whenever the new value depends on the old one, e.g. a body
    section); `expect` refuses the write if the item's version moved since the caller read it."""
    with _locked():
        if expect is not None and version(item_id) != expect:
            raise Stale(f"{item_id} changed since version {expect} — read it again")
        item = read(item_id)
        if edit is not None:
            fields = {**fields, **(edit(dict(item)) or {})}
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
    """POST /todo-item {id, set: {state?, rank?}, expect?} or {ranks: {id: n}} — the tracker page's moves;
    `expect` (a `version`) answers 409 instead of writing over a change the page hasn't seen;
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
        item = update(d.get("id", ""), expect=d.get("expect"), **fields)
    except Stale as e:
        return req._send(409, json.dumps({"ok": False, "error": str(e)}))
    except (OSError, ValueError, tomllib.TOMLDecodeError) as e:
        return req._send(400, json.dumps({"ok": False, "error": str(e)}))
    journal = None
    if fields.get("state") in ("done", "dropped"):
        import sqlite3
        from . import workjournal
        try:
            closed = workjournal.tracker_closed(item["id"], item.get("incarnation"), fields["state"], via="tracker-page")
            journal = closed and {k: closed.get(k) for k in ("verdict", "reason", "work_id", "retired_at") if k in closed}
        except (ValueError, sqlite3.Error) as e:
            journal = {"error": str(e)}
    state.poke()
    req._send(200, json.dumps({"ok": True, "item": item, "journal": journal}))
