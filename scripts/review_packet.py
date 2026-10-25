#!/usr/bin/env python3
"""review_packet — the PR body a branch publishes with: a contract a reviewer (human or the
john-hankles bot) checks the diff against, readable in under a minute.

    ## Intent            2–5 checkable claims (hand-edited; seeded from description + outline)
    ## Not in this PR    the forest's other jobs, open PR or "up next" (+ hand exclusions)
    ## Where this sits   merged ✓ · this PR → · up next ○, Stacked on, merge-after edges
    ## How to read it    file order, one line each (model-drafted per tree, else by layer)
    ## Verified          mechanical facts only: gates green for this tree, tests, migrations
    …the repo's PR template, unchanged

One renderer, two callers. The viewer server (srv/packet.py) feeds `build` facts it already
holds — snapshot config, cached PR state, the merge ledger — so the outbox spends no spawn per
node; this file's `gather` feeds the same function from git + gh for the CLI
(`stack-pr-body <b> --packet`). Only the hand parts are stored (branch.<b>.stack-packet, JSON):
the generated sections re-derive at publish time, so they cannot freeze stale.

    review_packet.py <branch>            the packet markdown, template included
    review_packet.py <branch> --json     the built sections
"""
import json
import os
import re
import subprocess
import sys

SECTIONS = ("Intent", "Not in this PR", "Where this sits", "How to read it", "Verified")
PACKET_KEY = "stack-packet"
LABEL = "ai-code-review"
MAX_CLAIMS = 5
MAX_READ = 12

_PREFIX = re.compile(r"^\w+(\([^)]*\))?!?:\s*")
_FOLLOWUP = re.compile(r"^(lint|format|fmt|oxfmt|typo|wip|fixup|squash|address review|review)\b", re.I)


# ── text helpers ───────────────────────────────────────────────────────────

def strip_prefix(subject):
    return _PREFIX.sub("", (subject or "").strip())


def _sentence(text):
    t = " ".join((text or "").split()).strip().rstrip(".;,")
    if not t:
        return ""
    return t[0].upper() + t[1:] + "."


def _third_person(text):
    """Description and subjects are imperative ("Forward a click…"); a claim states what the
    diff does ("Forwards a click…")."""
    words = text.split(" ", 1)
    w = words[0]
    lw = w.lower()
    if not w or not w[0].isalpha() or lw in ("no", "now", "only", "the", "a", "an", "each", "every"):
        return text
    if lw.endswith("s") and not lw.endswith("ss"):
        return text
    if lw.endswith(("ss", "sh", "ch", "x", "z", "o")):
        w += "es"
    elif lw.endswith("y") and len(lw) > 2 and lw[-2] not in "aeiou":
        w = w[:-1] + "ies"
    else:
        w += "s"
    return w + (" " + words[1] if len(words) > 1 else "")


def seed_intent(description, subjects):
    """Claims seeded from the description (split at its "so that" clause) and the commit
    outline's later steps — each a statement the diff can confirm or contradict."""
    claims = []
    desc = " ".join((description or "").split())
    if desc:
        parts = re.split(r",?\s+so(?: that)?\s+", desc, maxsplit=1)
        claims.append(_sentence(_third_person(parts[0])))
        if len(parts) > 1 and parts[1].strip():
            claims.append(_sentence(parts[1]))
    own = [strip_prefix(s) for s in subjects or [] if s and s.strip()]
    for s in own[1:] if desc else own:
        if _FOLLOWUP.match(s) or len(s.split()) < 2:
            continue
        c = _sentence(_third_person(s))
        if c.lower() not in {x.lower() for x in claims}:
            claims.append(c)
    return [c for c in claims if c][:MAX_CLAIMS]


# ── how to read it: the deterministic order ────────────────────────────────

LAYERS = ("schema", "queries", "models", "wiring", "ui", "other", "tests", "generated")


def layer_of(path):
    p = "/" + path.lower()
    base = os.path.basename(p)
    if (re.search(r"(^|/)(\.gen|generated|__generated__|dist)/", p) or base.endswith((".snap", ".lock"))
            or base in ("package-lock.json", "pnpm-lock.yaml", "yarn.lock")):
        return "generated"
    if re.search(r"\.(test|spec)\.[jt]sx?$", base) or re.search(r"/(__tests__|testing|e2e|tests?)/", p):
        return "tests"
    if "/migrations/" in p or base.endswith(".prisma") or base == "migration.sql":
        return "schema"
    if "/queries/" in p:
        return "queries"
    if "/models/" in p:
        return "models"
    if re.search(r"/(trpc|routers|pages/api|app/api|api|jobs|workers|script-runner|scripts|handlers)/", p):
        return "wiring"
    if base.endswith((".tsx", ".jsx", ".css", ".scss")) or re.search(r"/(components|hooks|pages|app|ui)/", p):
        return "ui"
    return "other"


_NOTE = {
    "schema": "schema / migration — read first", "queries": "data access", "models": "business logic",
    "wiring": "wiring", "ui": "UI", "other": "", "tests": "tests", "generated": "generated — skip",
}


def reading_order(files):
    """[{path, note}] by layer, queries → models → wiring → UI → tests; renames with no edits
    say they're moved verbatim; the biggest non-test change is called the core of it."""
    rows = []
    for f in files or []:
        lay = layer_of(f["path"])
        rows.append({**f, "layer": lay})
    rows.sort(key=lambda r: (LAYERS.index(r["layer"]), -(r.get("add", 0) + r.get("del", 0)), r["path"]))
    real = [r for r in rows if r["layer"] not in ("tests", "generated") and not _moved(r)]
    core = max(real, key=lambda r: r.get("add", 0), default=None) if len(real) > 1 else None
    out = []
    for r in rows:
        if _moved(r):
            note = f"skim — moved verbatim from `{r['old']}`"
        elif r.get("status") == "R":
            note = f"moved from `{r['old']}`, then edited"
        elif r is core:
            note = "the core of it" + (f" ({_NOTE[r['layer']]})" if _NOTE[r["layer"]] else "")
        elif r.get("status") == "D":
            note = "deleted"
        else:
            note = _NOTE[r["layer"]]
            if r["layer"] == "tests" and r.get("status") == "A":
                note = "new tests"
        out.append({"path": r["path"], "note": note})
    return out


def _moved(r):
    return r.get("status") == "R" and not r.get("add") and not r.get("del")


def read_lines(entries):
    lines = []
    for e in entries[:MAX_READ]:
        lines.append(f"`{e['path']}`" + (f" — {e['note']}" if e.get("note") else ""))
    if len(entries) > MAX_READ:
        lines.append(f"…and {len(entries) - MAX_READ} more")
    return lines


# ── where this sits / not in this PR ───────────────────────────────────────

def _ref(item):
    title = strip_prefix(item.get("title") or item.get("job") or item.get("branch") or "")
    return (f"#{item['pr']} {title}" if item.get("pr") else title).strip()


def where_lines(plan, stacked_on=None, after=None):
    """plan: every step in merge order, landed first — {pr, title, state, me}."""
    lines = []
    if stacked_on:
        lines.append(f"Stacked on: #{stacked_on['pr']}" if stacked_on.get("pr")
                     else f"Stacked on: `{stacked_on['branch']}` — its PR opens first")
        lines.append("")
    if len(plan) > 1:
        seen_me = False
        for s in plan:
            if s.get("me"):
                seen_me = True
                lines.append("→ **this PR**")
            elif s.get("state") == "merged":
                lines.append(f"✓ {_ref(s)}")
            else:
                state = "in review" if s.get("pr") else "up next" if seen_me else "not opened yet"
                lines.append(f"○ {_ref(s)} — {state}" + ("; this PR builds on it" if s.get("ancestor") else ""))
    for a in after or []:
        ref = f"#{a['pr']}" if a.get("pr") else f"`{a['branch']}`"
        why = a.get("why") or (strip_prefix(a.get("job") or "") and "deploy order: " + strip_prefix(a.get("job") or ""))
        lines.append(("" if not lines or lines[-1] == "" else "\n") + f"Merge after {ref}" + (f" — {why}" if why else ""))
    while lines and not lines[-1].strip():
        lines.pop()
    return lines


def not_lines(plan, hand=()):
    """Scope boundaries: every unmerged step that is neither this branch nor one it builds on."""
    out = []
    for s in plan:
        if s.get("me") or s.get("ancestor") or s.get("state") == "merged":
            continue
        job = " ".join((s.get("job") or s.get("title") or s.get("branch") or "").split()).rstrip(".")
        if not job:
            continue
        job = job[0].upper() + job[1:]
        out.append(f"{job} — #{s['pr']}" if s.get("pr") else f"{job} — up next")
    return out + [h for h in hand if h.strip()]


# ── verified ───────────────────────────────────────────────────────────────

def verified_lines(gates, files):
    out = []
    if gates and gates.get("green"):
        names = ", ".join(gates.get("names") or [])
        out.append(f"Pre-push gates green for this exact tree (`{gates['tree'][:10]}`)" + (f": {names}" if names else ""))
    tests = [f for f in files or [] if layer_of(f["path"]) == "tests" and f.get("status") != "D"]
    added = [f["path"] for f in tests if f.get("status") == "A"]
    changed = [f["path"] for f in tests if f.get("status") != "A"]
    if added:
        out.append("Tests added: " + ", ".join(f"`{p}`" for p in added[:6]) + (f" +{len(added) - 6} more" if len(added) > 6 else ""))
    if changed:
        out.append("Tests changed: " + ", ".join(f"`{p}`" for p in changed[:6]) + (f" +{len(changed) - 6} more" if len(changed) > 6 else ""))
    migs = [f["path"] for f in files or [] if f["path"].endswith("migration.sql") and f.get("status") != "D"]
    if migs:
        squawk = (gates or {}).get("squawk")
        note = " — squawk passed in the gates" if squawk is True else " — squawk failed in the gates" if squawk is False else ""
        out.append("Migration: " + ", ".join(f"`{p}`" for p in migs) + note)
    return out


# ── the packet ─────────────────────────────────────────────────────────────

def load_hand(raw):
    try:
        d = json.loads(raw) if raw else {}
    except ValueError:
        d = {}
    if not isinstance(d, dict):
        d = {}

    def lst(k):
        v = d.get(k)
        return [str(x).strip() for x in v if str(x).strip()] if isinstance(v, list) else None
    return {"lead": str(d.get("lead") or "").strip(), "intent": lst("intent"), "not": lst("not") or [],
            "read": lst("read")}


def build(f):
    """f: {description, subjects, hand, plan, stackedOn, after, files, guide, guideTree, gates}.
    Returns every section as lines, plus where each came from."""
    hand = f.get("hand") or load_hand("")
    seeded = seed_intent(f.get("description"), f.get("subjects"))
    if hand.get("read") is not None:
        read, read_src = hand["read"], "hand"
    elif f.get("guide"):
        read, read_src = read_lines(f["guide"]), "model"
    else:
        read, read_src = read_lines(reading_order(f.get("files"))), "layers"
    return {
        "lead": hand.get("lead", ""),
        "intent": hand["intent"] if hand.get("intent") is not None else seeded,
        "intentSource": "hand" if hand.get("intent") is not None else "seeded",
        "intentSeed": seeded,
        "notDerived": not_lines(f.get("plan") or []),
        "notHand": hand.get("not") or [],
        "read": read, "readSource": read_src, "readGenerated": (read_lines(f["guide"]) if f.get("guide")
                                                                 else read_lines(reading_order(f.get("files")))),
        "where": where_lines(f.get("plan") or [], f.get("stackedOn"), f.get("after")),
        "verified": verified_lines(f.get("gates"), f.get("files")),
    }


def _bullets(lines):
    return "\n".join(ln if ln.startswith(("- ", "Stacked on", "Merge after", "\n")) or not ln.strip()
                     else f"- {ln}" for ln in lines)


_STEP = re.compile(r"^\s+\S|^\s*(\d+\.\s|[-*•]\s|\[)")


def strip_plan(text):
    """The text without a generated "Part of a stack" block (outlineHints.stripPlan's rule: the
    block runs to the first blank line not followed by more steps — GitHub wraps long steps)."""
    lines, out, i = (text or "").split("\n"), [], 0
    while i < len(lines):
        if lines[i].strip() == "-- forest --":
            i += 1
            continue
        if lines[i].startswith("Part of "):
            while i + 1 < len(lines):
                if lines[i + 1].strip():
                    i += 1
                    continue
                j = i + 1
                while j < len(lines) and not lines[j].strip():
                    j += 1
                if j < len(lines) and _STEP.match(lines[j]):
                    i = j
                else:
                    break
            i += 1
            continue
        out.append(lines[i])
        i += 1
    return re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip()



def render(p, template=""):
    out = []
    if p.get("lead"):
        out.append(p["lead"].strip())
    if p.get("intent"):
        out.append("## Intent\n\n" + "\n".join(f"- {c}" for c in p["intent"]))
    nots = (p.get("notDerived") or []) + (p.get("notHand") or [])
    if nots:
        out.append("## Not in this PR\n\n" + "\n".join(f"- {n}" for n in nots))
    if p.get("where"):
        out.append("## Where this sits\n\n" + "\n".join(p["where"]))
    if p.get("read"):
        out.append("## How to read it\n\n" + "\n".join(f"{i}. {ln}" for i, ln in enumerate(p["read"], 1)))
    if p.get("verified"):
        out.append("## Verified\n\n" + "\n".join(f"- {v}" for v in p["verified"]))
    body = "\n\n".join(out)
    if template.strip():
        body = (body + "\n\n" if body else "") + template.strip()
    return body + "\n" if body else ""


# ── reading a published body back ──────────────────────────────────────────

_H2 = re.compile(r"^##\s+(.+?)\s*$", re.M)


def sections_of(body):
    """{heading: text} for every `## heading` in a body (text up to the next ## or a `---` rule)."""
    out = {}
    marks = list(_H2.finditer(body or ""))
    for i, m in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(body)
        text = body[m.end():end]
        text = re.split(r"^---\s*$", text, maxsplit=1, flags=re.M)[0]
        out[m.group(1).strip()] = text.strip()
    return out


def claims_of(body):
    text = sections_of(body).get("Intent", "")
    return [re.sub(r"^(\s*[-*]|\s*\d+[.)])\s+", "", ln).strip() for ln in text.splitlines()
            if re.match(r"^\s*([-*]|\d+[.)])\s+", ln)]


def splice(body, heading, text):
    """body with one section's text replaced (or the section dropped when text is empty)."""
    m = re.search(rf"^##\s+{re.escape(heading)}\s*$", body or "", re.M)
    if not m:
        return body
    nxt = re.compile(r"^(##\s|---\s*$)", re.M).search(body, m.end())
    end = nxt.start() if nxt else len(body)
    repl = f"## {heading}\n\n{text.strip()}\n\n" if text.strip() else ""
    return body[:m.start()] + repl + body[end:].lstrip("\n")


def _refs(text, mark):
    return {int(n) for n in re.findall(rf"{re.escape(mark)}\s+#(\d+)", text or "")}


def staleness(published_body, fresh_where):
    """What moved since the PR body was published: PRs merged or opened since. None when the
    published body has no Where-this-sits section to compare (a pre-packet PR)."""
    old = sections_of(published_body or "").get("Where this sits")
    if old is None:
        return None
    new = "\n".join(fresh_where)
    merged = sorted(_refs(new, "✓") - _refs(old, "✓"))
    opened = sorted(set(map(int, re.findall(r"#(\d+)", new))) - set(map(int, re.findall(r"#(\d+)", old))) - set(merged))
    stale = bool(merged or opened)
    return {"stale": stale, "mergedSince": merged, "openedSince": opened,
            "updatedBody": splice(published_body, "Where this sits", new) if stale else ""}


# ── bot findings → the claim each disputes ─────────────────────────────────

_STOP = set("this that with from into when then than have does each only also just over under them they their "
            "there here what which while about after before because should would could still were been being "
            "will your more most some such like make makes made code diff file line lines pull request".split())


def _words(text):
    return {w for w in re.findall(r"[a-z][a-z0-9_]+", (text or "").lower()) if len(w) >= 4 and w not in _STOP}


def _clean_finding(body):
    body = re.sub(r"```suggestion.*?```", "", body or "", flags=re.S)
    body = " ".join(body.split())
    return body[:320] + ("…" if len(body) > 320 else "")


def match_findings(claims, threads, bot="john-hankles"):
    """Unresolved bot threads, each placed under the Intent claim it disputes when it names it
    ("claim 2", the claim's words quoted, or most of its content words), else unplaced."""
    out = []
    cw = [_words(c) for c in claims]
    for t in threads or []:
        if t.get("resolved") or not (t.get("author") or "").startswith(bot):
            continue
        text = re.sub(r"```suggestion.*?```", "", t.get("body") or "", flags=re.S)
        low = " ".join(text.lower().split())
        idx = None
        m = re.search(r"\b(?:claim|intent)\s*#?(\d)\b", low)
        if m and 1 <= int(m.group(1)) <= len(claims):
            idx = int(m.group(1)) - 1
        if idx is None:
            for i, c in enumerate(claims):
                frag = " ".join(c.lower().rstrip(".").split())
                if len(frag) >= 20 and frag[:60] in low:
                    idx = i
                    break
        if idx is None and claims:
            fw = _words(text)
            best = max(range(len(claims)), key=lambda i: len(cw[i] & fw) / max(1, len(cw[i])))
            shared = cw[best] & fw
            if len(shared) >= 3 and len(shared) / max(1, len(cw[best])) >= 0.5:
                idx = best
        out.append({"path": t.get("path") or "", "line": t.get("line"), "url": t.get("url") or "",
                    "body": _clean_finding(text), "claim": idx, "outdated": bool(t.get("outdated"))})
    return out


# ── CLI: gather the same facts from git + gh ───────────────────────────────

def _git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True).stdout


def diff_files(base, tip, run=None):
    """[{path, old, status, add, del}] for base...tip, renames detected — one git call."""
    run = run or _git
    raw = run("diff", "--raw", "--numstat", "-M", "-z", f"{base}...{tip}")
    files, stats = [], []
    toks = raw.split("\0")
    i = 0
    while i < len(toks):
        t = toks[i]
        if t.startswith(":"):
            status = t.split()[-1][0]
            if status in "RC":
                files.append({"status": status, "old": toks[i + 1], "path": toks[i + 2]})
                i += 3
            else:
                files.append({"status": status, "old": "", "path": toks[i + 1]})
                i += 2
        elif t.strip():
            cols = t.split("\t")
            if len(cols) == 3 and cols[2] == "":
                stats.append((cols[0], cols[1]))
                i += 3
            else:
                stats.append((cols[0], cols[1]) if len(cols) >= 2 else ("0", "0"))
                i += 1
        else:
            i += 1
    for f, (a, d) in zip(files, stats):
        f["add"] = int(a) if a.isdigit() else 0
        f["del"] = int(d) if d.isdigit() else 0
    return files


def read_ledger(git_dir, project):
    try:
        with open(os.path.join(git_dir, "stack-project-merges.json")) as fh:
            hist = json.load(fh).get("merges", {}).get(project, [])
    except (OSError, ValueError, AttributeError):
        return []
    if isinstance(hist, dict):
        hist = [hist]
    return [{"pr": e.get("pr"), "title": e.get("title") or "", "branch": e.get("branch") or "", "state": "merged"}
            for e in reversed(hist)]


def guide_path(git_dir, branch, tree):
    safe = re.sub(r"[^A-Za-z0-9._-]", "~", branch)
    return os.path.join(git_dir, "stack-packet-guides", f"{safe}@{tree}.json")


def read_guide(git_dir, branch, tree):
    try:
        with open(guide_path(git_dir, branch, tree)) as fh:
            d = json.load(fh)
        return d.get("lines") or None
    except (OSError, ValueError):
        return None


def template_at(rev, run=None):
    return (run or _git)("show", f"{rev}:.github/pull_request_template.md").strip()


def gather(branch):
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, here)
    import stack_facts as sf
    gd = os.path.abspath(_git("rev-parse", "--git-common-dir").strip())
    project = sf.project_of(branch)
    prs = sf._prs() if project else {}
    landed = read_ledger(gd, project) if project else []
    order = [b for b in (sf._order(branch) if project else []) if not sf.plan_omitted(b)]
    landed_b = {s["branch"] for s in landed}
    anc, b = set(), sf.parent_of(branch)
    while b and b not in ("main", "master") and b not in anc:
        anc.add(b)
        anc.update(sf.requires_of(b))
        b = sf.parent_of(b)
    anc.update(sf.requires_of(branch))

    def title_of(x):
        return sf.cfg(f"branch.{x}.stack-pr-title") or _git("log", "--reverse", "--format=%s",
                                                            f"{_floor(sf, x)}..{x}").split("\n")[0]
    plan = list(landed)
    live = []
    for x in order:
        if x in landed_b:
            continue
        p = prs.get(x, {})
        live.append({"branch": x, "pr": p.get("pr"), "state": p.get("state"), "title": title_of(x),
                     "job": sf.job_of(x), "me": x == branch, "ancestor": x in anc})
    plan += [s for s in live if s.get("state") == "merged"] + [s for s in live if s.get("state") != "merged"]
    parent = sf.parent_of(branch)
    stacked = None
    if parent not in ("main", "master"):
        pp = prs.get(parent, {})
        if pp.get("state") != "merged":
            stacked = {"branch": parent, "pr": pp.get("pr")}
    after = [{"branch": a, "pr": prs.get(a, {}).get("pr"), "job": sf.job_of(a)} for a in sf.after_of(branch)]
    floor = _floor(sf, branch)
    files = diff_files(floor, branch)
    subjects = [s for s in _git("log", "--reverse", "--format=%s", f"{floor}..{branch}").splitlines() if s]
    tree = _git("rev-parse", f"{branch}^{{tree}}").strip()
    green = sf.cfg(f"branch.{branch}.stack-gates-green-tree") or sf.cfg(f"stack-branch.{branch}.gates-green-tree")
    return {
        "branch": branch, "description": sf.cfg(f"branch.{branch}.description"), "subjects": subjects,
        "hand": load_hand(sf.cfg(f"branch.{branch}.{PACKET_KEY}")), "plan": plan if len(plan) > 1 else [],
        "stackedOn": stacked, "after": after, "files": files, "tree": tree,
        "guide": read_guide(gd, branch, tree),
        "gates": {"green": bool(green) and green == tree, "tree": tree, "names": []},
        "template": template_at("origin/main") or template_at("main"),
    }


def _floor(sf, branch):
    parent = sf.parent_of(branch)
    if parent in ("main", "master"):
        return _git("merge-base", "origin/main", branch).strip() or parent
    return parent


def main(argv):
    if len(argv) < 2:
        print("usage: review_packet.py <branch> [--json]", file=sys.stderr)
        return 2
    f = gather(argv[1])
    p = build(f)
    if "--json" in argv:
        print(json.dumps(p, indent=1))
    else:
        sys.stdout.write(render(p, f["template"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
