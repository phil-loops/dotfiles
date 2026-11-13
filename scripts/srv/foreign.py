# srv/foreign.py — a teammate's PR stack as a forest, derived from GitHub (foreign forests, slice 2).
#
# The viewer's own forests live in git config (branch.<b>.stack-*); a teammate's stack has none, so
# it is derived, never configured: the repo's open PRs, each base → head ref chained into a parent
# edge (their PR bases point at each other). Read-only by construction — the one verb a foreign node
# will carry is preview (slice 3). GitHub is read through srv/openprs.py, the one owner of the open PRs, never written.
#
#   GET /foreign-stack?number=N   → {ok, root, nodes: [{number, title, head, base, parent, depth, author, draft, url}]}
import json
import re
from urllib.parse import parse_qs
from . import ctx, openprs



def stack_of(prs, number):
    """The stack that holds PR `number`, from open PRs as `gh pr list --json` gives them. Up: follow
    each base to the open PR whose head it is, until a base no open PR heads (main, or a branch that
    merged). Down: every open PR based on a node's head, depth first, children by number. A fork's
    PR heads a branch in the fork, not here — a fork PR named `main` must not root every stack —
    so it can sit in a stack but nothing chains on it. Pure."""
    by_head = {p["headRefName"]: p for p in prs if not p.get("isCrossRepository")}
    by_num = {p["number"]: p for p in prs}
    me = by_num.get(number)
    if not me:
        return None
    root, seen = me, {me["number"]}
    while root["baseRefName"] in by_head and by_head[root["baseRefName"]]["number"] not in seen:
        root = by_head[root["baseRefName"]]
        seen.add(root["number"])
    children = {}
    for p in prs:
        children.setdefault(p["baseRefName"], []).append(p)
    nodes, walked = [], set()

    def walk(p, parent, depth):
        if p["number"] in walked:
            return
        walked.add(p["number"])
        nodes.append({"number": p["number"], "title": p.get("title") or "", "head": p["headRefName"],
                      "base": p["baseRefName"], "parent": parent, "depth": depth,
                      "author": ((p.get("author") or {}).get("login") or ""), "draft": bool(p.get("isDraft")),
                      "url": p.get("url") or ""})
        if p.get("isCrossRepository"):
            return
        for c in sorted(children.get(p["headRefName"], []), key=lambda c: c["number"]):
            walk(c, p["number"], depth + 1)

    walk(root, None, 0)
    return {"root": root["number"], "nodes": nodes}


def _slug():
    url = ctx.run(["git", "remote", "get-url", "origin"]).stdout.strip()
    m = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", url) if url else None
    return m.group(1) if m else ""


def get(req, u):
    raw = (parse_qs(u.query).get("number") or [""])[0].lstrip("#")
    if not raw.isdigit():
        return req._send(400, json.dumps({"ok": False, "err": "want ?number=<PR number>"}))
    slug = _slug()
    prs = openprs.of_slug(slug) if slug else None
    if prs is None or (not prs and openprs.failed()):
        return req._send(200, json.dumps({"ok": False, "err": "GitHub didn't answer — gh pr list failed"}))
    s = stack_of(prs, int(raw))
    if s is None:
        return req._send(200, json.dumps({"ok": False, "err": f"#{raw} isn't an open PR"}))
    req._send(200, json.dumps({"ok": True, **s}))
