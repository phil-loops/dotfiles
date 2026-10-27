# srv/wiki.py — the viewer's wiki: durable prose about this repo, served alongside
# the forest instead of as a throwaway artifact.
#
# Two kinds of page, told apart by ONE frontmatter field:
#
#   map page     (no `project:`)  describes code that EXISTS. Every claim carries a
#                                 citation resolved against origin/main, and the lint
#                                 goes red when the code moves. True, or stale.
#   design page  (`project: <p>`) describes code that DOESN'T exist yet, bound to a
#                                 forest. Nothing to cite, so citations aren't demanded.
#                                 Agreed, or superseded.
#
# When a forest merges its design pages become citable — that's the moment to convert
# them (drop `project:`, add citations) rather than let them rot as a plan nobody
# reopens. /wiki/lint surfaces exactly that as `convertible`.
#
# Resolution, budget and the duplicate-prose detector are mail_map's, imported rather
# than reimplemented; this module adds page kinds and multi-root loading. mail_map.py
# folds in here once its content files go quiet (they're live in another session today).
import json
import os
import sys
from urllib.parse import parse_qs

from . import ctx

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import mail_map  # noqa: E402

HOME = os.path.expanduser("~")

# Content lives in dotfiles, never in the repo — a design doc must not turn up in a PR
# diff, and `git mv` restructuring is the property the format was built around.
WIKI_ROOT = os.environ.get("STACK_WIKI", os.path.join(HOME, ".dotfiles", "wiki"))

# mail-map's original home, still authoritative for loops until those pages move.
LEGACY = {"loops": os.path.join(HOME, ".dotfiles", "mail-map")}



def _repo_name():
    """The repo's name, identical from any of its worktrees.

    NOT the directory basename: the viewer is per-repo but gets launched from whichever
    worktree is handy, so a bounce from loops-wt-160721 would look for wiki/loops-wt-160721
    and silently serve nothing. The common git dir is shared by every worktree, so its
    parent names the repo no matter where the server started.
    """
    cwd = ctx.repo_cwd() or ctx.CWD or ""
    try:
        common = ctx.run(["git", "rev-parse", "--git-common-dir"]).stdout.strip()
    except Exception:
        common = ""
    if common:
        if not os.path.isabs(common):
            common = os.path.join(cwd, common)
        return os.path.basename(os.path.dirname(os.path.abspath(common))) or "repo"
    return os.path.basename(cwd) or "repo"


def _page_dirs():
    """Every directory holding pages for the active repo, preferred home first."""
    name = _repo_name()
    out = [os.path.join(WIKI_ROOT, name)]
    legacy = LEGACY.get(name)
    if legacy:
        out.append(legacy)
    return [d for d in out if os.path.isdir(d)]


def _load():
    """Every page for this repo, nav-ordered, each tagged with its kind.

    A slug found in more than one root resolves to the first — so moving a page into
    the new home shadows the legacy copy instead of colliding with it.
    """
    seen = {}
    problems = []
    for directory in _page_dirs():
        for name in sorted(os.listdir(directory)):
            if not name.endswith(".md"):
                continue
            slug = name[:-3]
            if slug in seen:
                continue
            with open(os.path.join(directory, name), encoding="utf-8") as fh:
                text = fh.read()
            try:
                meta, body = mail_map._parse_frontmatter(text, slug)
            except mail_map.Problem as exc:
                problems.append(str(exc))
                continue
            missing = [k for k in ("title", "section") if k not in meta]
            if missing:
                problems.append(f"{slug}: frontmatter is missing {', '.join(missing)}")
                continue
            project = meta.get("project", "")
            seen[slug] = {
                "slug": slug,
                "title": meta["title"],
                "section": meta["section"],
                "order": int(meta.get("order", "999")),
                "ask": meta.get("ask", ""),
                "lede": meta.get("lede", ""),
                "project": project,
                "kind": "design" if project else "map",
                "body": body,
                "words": len(body.split()),
                "dir": directory,
            }
    pages = sorted(seen.values(), key=lambda p: (p["order"], p["slug"]))
    return pages, problems


def _repo_ref():
    # mail_map resolves citations against a fixed REPO/REF pair chosen at import. The
    # viewer serves one repo per port, so pinning it per request is enough — and it
    # keeps a citation meaning the same thing regardless of the branch checked out.
    mail_map.REPO = ctx.repo_cwd() or ctx.CWD
    mail_map._cache.clear()


def pages(req, u):
    _repo_ref()
    try:
        found, problems = _load()
    except OSError as exc:
        return req._send(200, json.dumps({"err": str(exc)}))
    # An empty wiki has two very different causes and they must not look alike: a repo with
    # no content yet, versus a lookup pointing somewhere that doesn't exist. The second is a
    # bug (it shipped once — the repo was keyed on the launch directory), and it presented as
    # a serenely empty page. Name the searched paths so the UI can say which it is.
    searched = [os.path.join(WIKI_ROOT, _repo_name())]
    legacy = LEGACY.get(_repo_name())
    if legacy:
        searched.append(legacy)

    project = parse_qs(u.query).get("project", [""])[0]
    if project:
        found = [p for p in found if p["project"] == project]
    return req._send(200, json.dumps({
        "pages": found,
        "ref": mail_map.REF,
        "repo": _repo_name(),
        "problems": problems,
        "searched": searched,
        "roots": _page_dirs(),   # the subset of `searched` that actually exists
    }))


def src(req, u):
    _repo_ref()
    anchor = parse_qs(u.query).get("anchor", [""])[0]
    try:
        return req._send(200, json.dumps(mail_map.source_slice(anchor)))
    except mail_map.Problem as exc:
        return req._send(200, json.dumps({"err": str(exc)}))

