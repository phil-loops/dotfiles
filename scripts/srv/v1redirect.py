# srv/v1redirect.py — v1 is gone; a v1 URL answers 302 to its v2 page, so every link still pointing
# at v1 (bookmarks, old tabs, a stale producer) lands on v2. Pages v1 had and v2 doesn't (/work,
# /push, /outbox/launch, /watching, a terminal tutor session picked up by link — /tutor?import=)
# land on the v2 home. A forest's ~integration is its integration ref on the v2 review page.
from urllib.parse import parse_qsl, urlencode

from . import ctx

HOME = "/v2"


def v2_path(path):
    """The v2 page for a v1 path (segments kept as the browser encoded them); HOME when v2 has none."""
    segs = [s for s in path.split("/") if s]
    if segs == ["machine"]:
        return "/v2/machine"
    if segs and segs[0] in ("wiki", "tutor") and len(segs) <= 2:
        return "/v2/" + "/".join(segs)
    head, rest = (segs[0], segs[1:]) if segs else ("", [])
    repo = ctx.repo_name()
    if head == "forests" and rest:
        if rest[0] in (ctx.REPOS or {}):
            repo, rest = rest[0], rest[1:]
        if not rest:
            return HOME
        project, node = rest[0], rest[1:]
        if node == ["~integration"]:
            return f"/v2/b/{repo}/refs/stack/{project}-integration"
        if node and node[0].startswith("~"):   # no ref can contain "~"
            return HOME
        return f"/v2/b/{repo}/{'/'.join(node)}" if node else f"/v2/p/{repo}/{project}"
    if head == "branch" and rest:
        return f"/v2/b/{repo}/{'/'.join(rest)}"
    if head == "review" and len(rest) == 1 and rest[0].isdigit():
        return f"/v2/b/{repo}/review/pr-{rest[0]}"
    return HOME


def target(u):
    """Where a v1 page request goes instead: its v2 page (path + query, a stale ?v1 dropped)."""
    q = [(k, v) for k, v in parse_qsl(u.query, keep_blank_values=True) if k != "v1"]
    if any(k == "import" for k, _ in q) and u.path.startswith("/tutor"):
        return HOME
    to = v2_path(u.path)
    return to + ("?" + urlencode(q) if q and to != HOME else "")
