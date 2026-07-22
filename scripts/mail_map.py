"""Shared core for the mail map: page loading, citation resolution, and the checks.

Content lives in ~/.dotfiles/mail-map/*.md — one file per page. Nothing here renders
HTML; the server hands pages to the browser as JSON and the shell draws them. That
split is deliberate: restructuring the wiki is `git mv` plus a frontmatter edit, never
a surgery on markup.

A citation resolves against the working checkout, in one of three forms:

    path#symbolName      the definition of a symbol   (follows the code when it moves)
    path#/pattern/       the first line matching it   (for call sites)
    path#L12-L34@ab12    a literal range, pinned by a hash of its own lines

The first two are self-healing. The third can rot, so it carries a checksum of the
lines it points at and the linter goes red the moment they change.
"""

import hashlib
import os
import re

HOME = os.path.expanduser("~")
PAGES_DIR = os.environ.get("MAIL_MAP_PAGES", os.path.join(HOME, ".dotfiles", "mail-map"))
REPO = os.environ.get("MAIL_MAP_REPO", os.path.join(HOME, "coding", "loops"))

WORD_BUDGET = 260
CITE_RE = re.compile(r"\[([^\]]+)\]\(src:([^)\s]+)\)")
WIKILINK_RE = re.compile(r"\[\[([a-z0-9\-]+)\]\]")


class Problem(Exception):
    pass


# ---------------------------------------------------------------- pages


def _parse_frontmatter(text, slug):
    if not text.startswith("---\n"):
        raise Problem(f"{slug}: no frontmatter")
    _, raw, body = text.split("---\n", 2)
    meta = {}
    for line in raw.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if ":" not in line:
            raise Problem(f"{slug}: frontmatter line is not key: value → {line!r}")
        key, val = line.split(":", 1)
        meta[key.strip()] = val.strip()
    return meta, body.lstrip("\n")


def load_pages():
    """Every page, in nav order (`order` frontmatter, then slug)."""
    pages = []
    for name in sorted(os.listdir(PAGES_DIR)):
        if not name.endswith(".md"):
            continue
        slug = name[:-3]
        with open(os.path.join(PAGES_DIR, name), encoding="utf-8") as fh:
            meta, body = _parse_frontmatter(fh.read(), slug)
        for required in ("title", "section"):
            if required not in meta:
                raise Problem(f"{slug}: frontmatter is missing {required}")
        pages.append(
            {
                "slug": slug,
                "title": meta["title"],
                "section": meta["section"],
                "order": int(meta.get("order", "999")),
                "ask": meta.get("ask", ""),
                "lede": meta.get("lede", ""),
                "body": body,
                "words": len(body.split()),
            }
        )
    pages.sort(key=lambda p: (p["order"], p["slug"]))
    return pages


def citations(body):
    return [(m.group(1), m.group(2)) for m in CITE_RE.finditer(body)]


# ---------------------------------------------------------------- citations

_SYMBOL_RE = "(?:export\\s+)?(?:default\\s+)?(?:async\\s+)?(?:function|const|let|class|type|interface)\\s+{name}\\b"


def _read(path):
    full = os.path.join(REPO, path)
    if not os.path.exists(full):
        raise Problem(f"no such file in the checkout: {path}")
    with open(full, encoding="utf-8", errors="replace") as fh:
        return fh.read().splitlines()


def _block_end(lines, start):
    """End of the definition beginning at `start` (0-indexed), by brace balance."""
    depth = 0
    seen = False
    for i in range(start, min(len(lines), start + 400)):
        depth += lines[i].count("{") + lines[i].count("(") + lines[i].count("[")
        depth -= lines[i].count("}") + lines[i].count(")") + lines[i].count("]")
        if depth > 0:
            seen = True
        if seen and depth <= 0:
            return i
        if not seen and lines[i].rstrip().endswith(";"):
            return i
    return min(len(lines) - 1, start + 40)


def resolve(anchor):
    """anchor → {path, start, end, lines, kind}. 1-indexed, inclusive."""
    if "#" not in anchor:
        raise Problem(f"citation has no anchor: {anchor}")
    path, frag = anchor.split("#", 1)
    lines = _read(path)

    ranged = re.fullmatch(r"L(\d+)(?:-L(\d+))?(?:@([0-9a-f]{4,}))?", frag)
    if ranged:
        start = int(ranged.group(1))
        end = int(ranged.group(2) or start)
        if end > len(lines):
            raise Problem(f"{path}: cited lines {start}-{end} but the file has {len(lines)}")
        body = lines[start - 1 : end]
        got = hashlib.sha256("\n".join(body).encode()).hexdigest()[:8]
        want = ranged.group(3)
        if not want:
            raise Problem(f"{path}#{frag}: a line range must be pinned — write @{got}")
        if not got.startswith(want):
            raise Problem(f"{path}#{frag}: those lines changed (now @{got}) — reread and repin")
        return {"path": path, "start": start, "end": end, "lines": body, "kind": "range"}

    if frag.startswith("/") and frag.endswith("/") and len(frag) > 2:
        pattern = frag[1:-1]
        for i, line in enumerate(lines):
            if re.search(pattern, line):
                return {
                    "path": path,
                    "start": i + 1,
                    "end": _block_end(lines, i) + 1,
                    "lines": lines[i : _block_end(lines, i) + 1],
                    "kind": "match",
                }
        raise Problem(f"{path}: nothing matches /{pattern}/")

    if not re.fullmatch(r"\w+", frag):
        raise Problem(f"unreadable anchor: {anchor}")
    rx = re.compile(_SYMBOL_RE.format(name=re.escape(frag)))
    for i, line in enumerate(lines):
        if rx.search(line):
            end = _block_end(lines, i)
            return {
                "path": path,
                "start": i + 1,
                "end": end + 1,
                "lines": lines[i : end + 1],
                "kind": "symbol",
            }
    raise Problem(f"{path}: no definition of `{frag}`")


def source_slice(anchor, context=3):
    """A resolved citation plus a few lines either side, for showing in place."""
    hit = resolve(anchor)
    lines = _read(hit["path"])
    top = max(1, hit["start"] - context)
    bottom = min(len(lines), hit["end"] + context)
    return {
        "path": hit["path"],
        "start": hit["start"],
        "end": hit["end"],
        "from": top,
        "text": "\n".join(lines[top - 1 : bottom]),
        "kind": hit["kind"],
    }


# ---------------------------------------------------------------- checks


def _shingles(body, n=8):
    words = re.sub(r"[^a-z0-9 ]", " ", CITE_RE.sub(r"\1", body).lower()).split()
    return {" ".join(words[i : i + n]) for i in range(max(0, len(words) - n + 1))}


def check(pages=None):
    """Every deterministic check. Returns a list of (severity, message)."""
    pages = pages or load_pages()
    out = []
    slugs = {p["slug"] for p in pages}
    seen_anchors = {}

    for page in pages:
        if page["words"] > WORD_BUDGET:
            out.append(
                ("over-budget", f"{page['slug']}: {page['words']} words, budget is {WORD_BUDGET} — split it or cut")
            )
        cites = citations(page["body"])
        if not cites:
            out.append(("uncited", f"{page['slug']}: makes claims with no citation"))
        for _, anchor in cites:
            try:
                resolve(anchor)
            except Problem as exc:
                out.append(("broken-citation", f"{page['slug']}: {exc}"))
            owner = seen_anchors.setdefault(anchor, page["slug"])
            if owner != page["slug"]:
                out.append(
                    ("duplicate-citation", f"{page['slug']}: cites {anchor}, already explained on {owner} — link instead")
                )
        for target in WIKILINK_RE.findall(page["body"]):
            if target not in slugs:
                out.append(("dead-link", f"{page['slug']}: [[{target}]] is not a page"))
        if page["ask"]:
            try:
                _read(page["ask"])
            except Problem as exc:
                out.append(("broken-ask", f"{page['slug']}: {exc}"))

    for i, a in enumerate(pages):
        sa = _shingles(a["body"])
        for b in pages[i + 1 :]:
            sb = _shingles(b["body"])
            if not sa or not sb:
                continue
            overlap = len(sa & sb) / min(len(sa), len(sb))
            if overlap > 0.12:
                out.append(
                    ("duplicate-prose", f"{a['slug']} ↔ {b['slug']}: {overlap:.0%} of the shorter page is shared wording")
                )
    return out
