# srv/v1redirect.py — a v1 URL with a v2 page answers 302 to it, so every link still pointing at v1
# (bookmarks, old tabs, a producer not yet moved) lands on v2. Pages v2 doesn't have (/work, /wiki,
# /tutor, /push, /outbox/launch) keep serving v1. A forest's ~integration is its integration ref on
# the v2 review page.
#
#   `git config stack.viewer-v1-redirect false` (server repo or global) turns every redirect off;
#   `?v1` on any URL bypasses it for that load, so v1 stays reachable while it still exists.
import time
from urllib.parse import parse_qsl, urlencode

from . import ctx

_ON = {"at": 0.0, "on": True}


def enabled():
    now = time.monotonic()
    if now - _ON["at"] > 2:
        r = ctx.run(["git", "-C", ctx.CWD, "config", "--type=bool", "--get", "stack.viewer-v1-redirect"])
        _ON.update(at=now, on=r.stdout.strip() != "false")
    return _ON["on"]


def v2_path(path):
    """The v2 page for a v1 path (segments kept as the browser encoded them), or None."""
    segs = [s for s in path.split("/") if s]
    if segs in ([], ["index.html"], ["forests"], ["outbox"]):
        return "/v2"
    if segs == ["machine"]:
        return "/v2/machine"
    head, rest = segs[0], segs[1:]
    repo = ctx.repo_name()
    if head == "forests":
        if rest[0] in (ctx.REPOS or {}):
            repo, rest = rest[0], rest[1:]
        if not rest:
            return "/v2"
        project, node = rest[0], rest[1:]
        if node == ["~integration"]:
            return f"/v2/b/{repo}/refs/stack/{project}-integration"
        if node and node[0].startswith("~"):   # no ref can contain "~"
            return None
        return f"/v2/b/{repo}/{'/'.join(node)}" if node else f"/v2/p/{repo}/{project}"
    if head == "branch" and rest:
        return f"/v2/b/{repo}/{'/'.join(rest)}"
    if head == "review" and len(rest) == 1 and rest[0].isdigit():
        return f"/v2/b/{repo}/review/pr-{rest[0]}"
    return None


def target(u):
    """Where a v1 page request should go instead (path + query, ?v1 dropped), or None to serve v1."""
    q = parse_qsl(u.query, keep_blank_values=True)
    if any(k == "v1" for k, _ in q) or not enabled():
        return None
    to = v2_path(u.path)
    if to is None:
        return None
    return to + ("?" + urlencode(q) if q else "")
