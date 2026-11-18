# srv/openprs.py — the repo's open PRs: the one owner of "which PRs are open" and what GitHub says
# about each. It replaces three sweeps of the same list (sync's heads, the outbox's detail, the
# teammate-stack reader) that refreshed on their own clocks and could disagree about a PR.
#
#   listing   one cheap sweep across origin AND the phil-loops fork (Phil's real PRs are on origin,
#             the fork is the automation surface; missing either lets prep rewrite a published
#             branch — #9405). It defines membership. Stale-while-revalidate at 30 s; a mutating
#             guard asks fresh=True and blocks on a live sweep unless one landed in the last 5 s.
#   detail    mergeability and approvals, which cost GitHub ~2 s: origin only, 90 s, never blocks
#             (a cold read answers {} and fills behind). Rows outside the listing are dropped, so
#             detail can decorate a PR but never add one.
#
# On a total gh outage the last-good listing stays and `failed()` says so: a guard must not read
# "not in the set" as "unpublished" when the set is a guess.
import json
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from . import ctx

FIELDS = "number,title,headRefName,baseRefName,author,isDraft,url,isCrossRepository"
DETAIL_FIELDS = "number,headRefName,headRefOid,mergeStateStatus,mergeable,baseRefName,createdAt,latestReviews,reviews"
TTL, FRESH_TTL, DETAIL_TTL = 30.0, 5.0, 90.0
REMOTES = ("origin", "phil-loops")

_lock = threading.Lock()
_listing = {}      # repo -> {"at": monotonic, "prs": [pr + "slug"] | None, "outage": bool}
_detail = {}       # repo -> {"at": monotonic, "data": {head: {...}}}
_busy = set()      # (kind, repo) with a background sweep in flight


def _slugs():
    """owner/repo for each remote, resolved in the CALLING thread (ctx.run's repo binding is
    thread-local, so a background sweep can't resolve them itself)."""
    out = []
    for remote in REMOTES:
        url = ctx.run(["git", "remote", "get-url", remote]).stdout.strip()
        m = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", url) if url else None
        if m:
            out.append(m.group(1))
    return out


def _sweep(slugs):
    """Every open PR on these slugs, in parallel; None when gh answered for none of them."""
    def one(slug):
        r = ctx.run(["gh", "pr", "list", "-R", slug, "--state", "open", "--json", FIELDS, "--limit", "300"], timeout=30)
        if r.returncode != 0:
            return None
        try:
            return [dict(p, slug=slug) for p in json.loads(r.stdout or "[]")]
        except ValueError:
            return None
    if not slugs:
        return None
    with ThreadPoolExecutor(max_workers=len(slugs)) as ex:
        got = [res for res in ex.map(one, slugs) if res is not None]
    return [p for res in got for p in res] if got else None


def _store(repo, prs):
    with _lock:
        ent = _listing.setdefault(repo, {"at": -1e9, "prs": None, "outage": False})
        ent["outage"] = prs is None
        if prs is not None:
            ent["prs"] = prs
        elif ent["prs"] is None:
            ent["prs"] = []   # an outage on a cold cache: empty, so every call doesn't block again
        ent["at"] = time.monotonic()
        return ent["prs"]


def _refresh(repo, slugs):
    try:
        _store(repo, _sweep(slugs))
    finally:
        _busy.discard(("listing", repo))


def listing(fresh=False):
    """Every open PR of the request's repo, each with its `slug`."""
    repo = ctx.repo_cwd()
    with _lock:
        ent = _listing.get(repo)
        if ent and ent["prs"] is not None:
            age = time.monotonic() - ent["at"]
            if not fresh or age < FRESH_TTL:
                if not fresh and age >= TTL and ("listing", repo) not in _busy:
                    _busy.add(("listing", repo))
                    threading.Thread(target=_refresh, args=(repo, _slugs()), daemon=True).start()
                return ent["prs"]
    return _store(repo, _sweep(_slugs()))


def heads(fresh=False):
    """Branch names with an open PR on either remote — a fork's head too: for a guard against
    rewriting published work, a name counted published by mistake is the safe error."""
    return {p["headRefName"] for p in listing(fresh)}


def failed():
    """The last sweep got nothing from gh: the listing is last-good (or empty), not evidence."""
    with _lock:
        return bool((_listing.get(ctx.repo_cwd()) or {}).get("outage"))


def of_slug(slug):
    """The open PRs on one slug (a teammate's stack lives on origin)."""
    return [p for p in listing() if p.get("slug") == slug]


def _fetch_detail(slug):
    r = ctx.run(["gh", "pr", "list", "-R", slug, "--state", "open", "--limit", "300", "--json", DETAIL_FIELDS], timeout=30)
    if r.returncode != 0:
        return None
    try:
        rows = json.loads(r.stdout or "[]")
    except ValueError:
        return None
    out = {}
    for p in rows:
        approvals = [rv for rv in p.get("latestReviews") or [] if rv.get("state") == "APPROVED"]
        # the commit the newest approval saw: an approval counts only for that code (latestReviews omits it)
        approved = max((rv for rv in p.get("reviews") or [] if rv.get("state") == "APPROVED"),
                       key=lambda rv: rv.get("submittedAt") or "", default=None)
        out[p.get("headRefName")] = {
            "number": p.get("number"),
            "mergeState": p.get("mergeStateStatus") or "",
            "mergeable": p.get("mergeable") or "",
            "baseRef": p.get("baseRefName") or "",
            "createdAt": p.get("createdAt") or "",
            "approvals": len(approvals),
            "approvedAt": max((rv.get("submittedAt") or "" for rv in approvals), default=""),
            "headSha": p.get("headRefOid") or "",
            "approvedSha": ((approved or {}).get("commit") or {}).get("oid") or "",
        }
    return out


def _refresh_detail(repo, slug):
    try:
        got = _fetch_detail(slug)
        if got is not None:
            with _lock:
                _detail[repo] = {"at": time.monotonic(), "data": got}
    finally:
        _busy.discard(("detail", repo))


def detail():
    """{head: mergeability + approvals} for open PRs on origin; {} until the first sweep lands."""
    repo = ctx.repo_cwd()
    with _lock:
        ent = _detail.get(repo)
        if (not ent or time.monotonic() - ent["at"] >= DETAIL_TTL) and ("detail", repo) not in _busy:
            slugs = _slugs()[:1]
            if slugs:
                _busy.add(("detail", repo))
                threading.Thread(target=_refresh_detail, args=(repo, slugs[0]), daemon=True).start()
        data = dict(ent["data"]) if ent else {}
    open_numbers = {p.get("number") for p in (_listing.get(repo) or {}).get("prs") or ()}
    return {h: {k: v for k, v in d.items() if k != "number"} for h, d in data.items()
            if not open_numbers or d.get("number") in open_numbers}


def seed(repo, prs, outage=False):
    """A test's open PRs, as a fresh sweep would have left them (heads only is enough)."""
    rows = [p if isinstance(p, dict) else {"headRefName": p, "number": i + 1, "slug": "test/test"} for i, p in enumerate(prs)]
    with _lock:
        _listing[repo] = {"at": time.monotonic(), "prs": rows, "outage": outage}
