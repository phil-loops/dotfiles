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
import re
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

# `[label](src:…)` that CITE_RE will NOT match — an anchor with a space in it. Caught
# explicitly because the failure is otherwise invisible: it renders as plain text.
MALFORMED_RE = re.compile(r"\]\(src:([^)]*\s[^)]*)\)")


def _repo_name():
    return os.path.basename(ctx.repo_cwd() or ctx.CWD or "").replace(".git", "") or "repo"


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


def _live_projects():
    """Forest names this repo still knows about. Empty on any git trouble — the caller
    only uses it to *raise* a hint, so failing closed keeps a hiccup from crying wolf."""
    try:
        proc = ctx.run(["git", "config", "--get-regexp", r"^stack-project\..*\.branch$"])
    except Exception:
        return None
    if proc.returncode != 0:
        return None
    return {line.split(".", 2)[1] for line in proc.stdout.splitlines() if line.startswith("stack-project.")}


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
    project = parse_qs(u.query).get("project", [""])[0]
    if project:
        found = [p for p in found if p["project"] == project]
    return req._send(200, json.dumps({
        "pages": found,
        "ref": mail_map.REF,
        "repo": _repo_name(),
        "problems": problems,
    }))


def src(req, u):
    _repo_ref()
    anchor = parse_qs(u.query).get("anchor", [""])[0]
    try:
        return req._send(200, json.dumps(mail_map.source_slice(anchor)))
    except mail_map.Problem as exc:
        return req._send(200, json.dumps({"err": str(exc)}))


def lint(req, u):
    """Deterministic checks, kind-aware.

    A design page is exempt from the citation demands — it describes code that hasn't
    been written, so `uncited` and `broken-citation` would fire on every line of an
    honest plan. It still owes a word budget and live wikilinks: those are the
    anti-additive part, and a plan that sprawls is exactly what needs splitting.
    """
    _repo_ref()
    try:
        found, problems = _load()
    except OSError as exc:
        return req._send(200, json.dumps({"err": str(exc)}))

    out = [{"kind": "frontmatter", "msg": m} for m in problems]
    slugs = {p["slug"] for p in found}
    seen_anchors = {}
    live = _live_projects()   # one git call for the whole pass, not one per page

    for page in found:
        design = page["kind"] == "design"
        if page["words"] > mail_map.WORD_BUDGET:
            out.append({"kind": "over-budget", "slug": page["slug"],
                        "msg": f"{page['words']} words, budget is {mail_map.WORD_BUDGET} — split it or cut"})
        # A citation whose anchor holds a space doesn't match CITE_RE, so it renders as
        # literal text and every other check skips it — silent, and it cost an hour once.
        for bad in MALFORMED_RE.findall(page["body"]):
            out.append({"kind": "malformed-citation", "slug": page["slug"],
                        "msg": f"src:{bad.strip()} — an anchor can't contain spaces; "
                               "use path#symbol, path#/pattern/ (no spaces), or path#L1-L2@hash"})
        cites = mail_map.citations(page["body"])
        if not cites and not design:
            out.append({"kind": "uncited", "slug": page["slug"],
                        "msg": "makes claims with no citation"})
        for _, anchor in cites:
            try:
                mail_map.resolve(anchor)
            except mail_map.Problem as exc:
                if not design:
                    out.append({"kind": "broken-citation", "slug": page["slug"], "msg": str(exc)})
            owner = seen_anchors.setdefault(anchor, page["slug"])
            if owner != page["slug"] and not design:
                out.append({"kind": "duplicate-citation", "slug": page["slug"],
                            "msg": f"cites {anchor}, already explained on {owner} — link instead"})
        for target in mail_map.WIKILINK_RE.findall(page["body"]):
            if target not in slugs:
                out.append({"kind": "dead-link", "slug": page["slug"],
                            "msg": f"[[{target}]] is not a page"})
        if page["ask"] and not design:
            try:
                mail_map._read(page["ask"])
            except mail_map.Problem as exc:
                out.append({"kind": "broken-ask", "slug": page["slug"], "msg": str(exc)})
        # The conversion prompt. Resolving citations can't be the signal — a plan may
        # legitimately cite code that already exists on the write side. The forest
        # vanishing from config is the honest one: restack contracts a project's keys
        # once its last branch merges, so an orphaned `project:` means the work landed.
        if design and live is not None and page["project"] not in live:
            out.append({"kind": "convertible", "slug": page["slug"],
                        "msg": f"no forest named {page['project']} — the work landed or was dropped; "
                               "cite the real code and drop `project:`, or retire the page"})

    for i, a in enumerate(found):
        sa = mail_map._shingles(a["body"])
        for b in found[i + 1:]:
            sb = mail_map._shingles(b["body"])
            if not sa or not sb:
                continue
            overlap = len(sa & sb) / min(len(sa), len(sb))
            if overlap > 0.12:
                out.append({"kind": "duplicate-prose", "slug": a["slug"],
                            "msg": f"↔ {b['slug']}: {overlap:.0%} of the shorter page is shared wording"})

    return req._send(200, json.dumps({"problems": out}))
