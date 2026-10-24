# srv/ghreview.py — the ONE place the viewer talks to GitHub about reviews: the shape of a PR's
# review data (threads with full comment chains, reviews, top-level comments, the viewer's own
# pending review), and every review mutation the branch page can make.
#
# Reads ride packet.py's background GraphQL read (one poller per repo, PR_FIELDS below), which
# hands each PR to absorb(); a write refetches just its PR right after, so the page settles on
# GitHub's own answer instead of waiting out the poll.
#
# Writes go through mutate(), which picks the backend:
#   $STACK_REVIEW_GH_FAKE=<file>   a JSON fake GitHub (viewer-sandbox --github, every test): reads and
#                                  writes that file, never the network
#   otherwise                      `gh api graphql` — refused outright under STACK_REVIEW_SANDBOX=1,
#                                  and unless the request is Phil's browser acting on a keypress or
#                                  click (actor "browser", X-Stack-Via, same-origin fetch)
# A queued reply (one that names an unpushed commit) was typed and sent by that same gesture; the
# server only releases it once its commits are on origin.
import json
import os
import subprocess
import threading
import time

from . import ctx, linemap

FAKE_ENV = "STACK_REVIEW_GH_FAKE"
BOT = "john-hankles"

PR_FIELDS = """id number headRefName headRefOid baseRefName title body url state author { login }
  reviewThreads(first: 100) { nodes { id isResolved isOutdated path line originalLine startLine originalStartLine
    diffSide subjectType viewerCanResolve viewerCanUnresolve viewerCanReply
    comments(first: 50) { nodes { id databaseId author { login } body createdAt url commit { oid } originalCommit { oid }
      diffHunk reactionGroups { content reactors { totalCount } } } } } }
  reviews(last: 50) { nodes { id state author { login } body submittedAt url } }
  pending: reviews(states: PENDING, first: 1) { nodes { id comments { totalCount } } }
  comments(last: 50) { nodes { id author { login } body createdAt url } }
  commits(last: 10) { nodes { commit { checkSuites(first: 20) { nodes { conclusion
    workflowRun { workflow { name } } } } } } }"""

_login = lambda n: ((n or {}).get("author") or {}).get("login") or "ghost"   # noqa: E731


def parse_pr(pr):
    """One GraphQL pullRequest node → the normalized PR every reader uses."""
    threads = []
    for t in (pr.get("reviewThreads") or {}).get("nodes") or []:
        cs = (t.get("comments") or {}).get("nodes") or []
        comments = []
        for i, c in enumerate(cs):
            reactions = {g["content"]: g["reactors"]["totalCount"] for g in c.get("reactionGroups") or []
                         if (g.get("reactors") or {}).get("totalCount")}
            comments.append({"id": c.get("id") or "", "db": c.get("databaseId"), "author": _login(c),
                             "body": c.get("body") or "", "at": c.get("createdAt") or "", "url": c.get("url") or "",
                             "commit": (c.get("commit") or {}).get("oid") or "",
                             "originalCommit": (c.get("originalCommit") or {}).get("oid") or "",
                             **({"hunk": c.get("diffHunk") or ""} if i == 0 else {}),
                             **({"reactions": reactions} if reactions else {})})
        line, start = t.get("line"), t.get("startLine")
        ostart = t.get("originalStartLine")
        threads.append({
            "node": t.get("id") or "", "path": t.get("path") or "",
            "line": line, "startLine": start if start and start != line else None,
            "originalLine": t.get("originalLine"),
            "originalStartLine": ostart if ostart and ostart != t.get("originalLine") else None,
            "side": t.get("diffSide") or "RIGHT", "subject": t.get("subjectType") or "LINE",
            "outdated": bool(t.get("isOutdated")), "resolved": bool(t.get("isResolved")),
            "canResolve": bool(t.get("viewerCanResolve")), "canUnresolve": bool(t.get("viewerCanUnresolve")),
            "canReply": bool(t.get("viewerCanReply", True)), "comments": comments,
        })
    reviews = [{"id": r.get("id") or "", "author": _login(r), "state": r.get("state") or "", "body": r.get("body") or "",
                "at": r.get("submittedAt") or "", "url": r.get("url") or ""}
               for r in (pr.get("reviews") or {}).get("nodes") or [] if r.get("state") != "PENDING"]
    pend = ((pr.get("pending") or {}).get("nodes") or [None])[0]
    ran = any(s.get("conclusion") == "SUCCESS" and ((s.get("workflowRun") or {}).get("workflow") or {}).get("name") == "code-review"
              for cm in (pr.get("commits") or {}).get("nodes") or []
              for s in ((cm.get("commit") or {}).get("checkSuites") or {}).get("nodes") or [])
    return {
        "id": pr.get("id") or "", "number": pr.get("number"), "headRef": pr.get("headRefName") or "",
        "head": pr.get("headRefOid") or "", "base": pr.get("baseRefName") or "", "title": pr.get("title") or "",
        "body": pr.get("body") or "", "url": pr.get("url") or "", "state": pr.get("state") or "OPEN",
        "author": _login(pr), "botRan": ran, "threads": threads, "reviews": reviews,
        "comments": [{"id": c.get("id") or "", "author": _login(c), "body": c.get("body") or "",
                      "at": c.get("createdAt") or "", "url": c.get("url") or ""}
                     for c in (pr.get("comments") or {}).get("nodes") or []],
        "pending": {"id": pend.get("id"), "count": ((pend.get("comments") or {}).get("totalCount") or 0)} if pend else None,
    }


def legacy_threads(full):
    """The packet's older per-thread view (first comment only), derived from the full read."""
    out = []
    for t in full["threads"]:
        c = t["comments"][0] if t["comments"] else {}
        out.append({"author": c.get("author", ""), "body": c.get("body", ""), "url": c.get("url", ""),
                    "path": t["path"], "line": t["line"], "resolved": t["resolved"], "outdated": t["outdated"]})
    return out


# ── the read cache: filled by packet's poller and by refetch() ───────────────

_FULL = {}      # repo -> {number: normalized pr + "at"}
_VIEWER = {}    # repo -> login
_LOCK = threading.Lock()


def absorb(repo, full, viewer=None):
    with _LOCK:
        _FULL.setdefault(repo, {})[full["number"]] = {**full, "at": time.time()}
        if viewer:
            _VIEWER[repo] = viewer


def viewer():
    fake = _fake()
    if fake:
        return fake.load().get("viewer") or "you"
    return _VIEWER.get(ctx.repo_cwd()) or ""


def cached(numbers):
    """{number: pr} for these numbers, from the fake or the poller's cache (no network here)."""
    fake = _fake()
    if fake:
        return {n: p for n, p in fake.read().items() if n in numbers}
    with _LOCK:
        have = _FULL.get(ctx.repo_cwd(), {})
        return {n: have[n] for n in numbers if n in have}


def refetch(number):
    """Re-read one PR now (after a write), into the cache. Returns it, or None."""
    fake = _fake()
    if fake:
        return fake.read().get(number)
    from . import outbox, packet, repostate
    slug = outbox._slug(repostate.snapshot())
    owner, _, name = slug.partition("/")
    q = "query { viewer { login } repository(owner: %s, name: %s) { pullRequest(number: %d) { %s } } }" % (
        json.dumps(owner), json.dumps(name), int(number), PR_FIELDS)
    r = ctx.run(["gh", "api", "graphql", "-f", f"query={q}"], timeout=40)
    try:
        data = json.loads(r.stdout or "{}").get("data") or {}
    except ValueError:
        return None
    node = (data.get("repository") or {}).get("pullRequest")
    if r.returncode != 0 or not node:
        return None
    full = parse_pr(node)
    absorb(ctx.repo_cwd(), full, (data.get("viewer") or {}).get("login"))
    packet.absorb_one(full)
    return full


# ── backends ─────────────────────────────────────────────────────────────

class Refused(Exception):
    pass


def _fake():
    path = os.environ.get(FAKE_ENV)
    return FakeGitHub(path) if path else None


def fake_prs():
    """{number: pr} from the fake GitHub, or None when the real one is in use."""
    fake = _fake()
    return fake.read() if fake else None


class FakeGitHub:
    """A GitHub that lives in one JSON file: {viewer, prs: {number: normalized pr}, seq, log}. Its PRs'
    heads follow origin's refs the way GitHub's do on a push: threads re-anchor, and one whose
    lines the pushed commits changed turns outdated."""
    _lock = threading.Lock()

    def __init__(self, path):
        self.path = path

    def load(self):
        try:
            with open(self.path) as f:
                return json.load(f)
        except (OSError, ValueError):
            return {"viewer": "you", "prs": {}, "seq": 0, "log": []}

    def _save(self, d):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(d, f, indent=1)
        os.replace(tmp, self.path)

    def read(self):
        with self._lock:
            d = self.load()
            moved = False
            for pr in d["prs"].values():
                head = subprocess.run(["git", "rev-parse", "-q", "--verify", f"refs/remotes/origin/{pr['headRef']}"],
                                      cwd=ctx.repo_cwd(), capture_output=True, text=True).stdout.strip()
                if head and head != pr["head"]:
                    self._push(pr, head)
                    moved = True
            if moved:
                self._save(d)
            return {int(n): pr for n, pr in d["prs"].items()}

    @staticmethod
    def _push(pr, head):
        paths = sorted({t["path"] for t in pr["threads"] if not t["outdated"]})
        walk = linemap.commits_between(pr["head"], head, paths)["walk"]
        for t in pr["threads"]:
            if t["outdated"] or t["line"] is None:
                continue
            at = linemap.locate(walk, t["path"], t["startLine"] or t["line"], t["line"])
            if at["addressedBy"] is not None:
                t.update(outdated=True, line=None, startLine=None)
            else:
                t.update(line=at["line"], startLine=at["startLine"])
        pr["head"] = head

    def mutate(self, op, args):
        with self._lock:
            d = self.load()
            d["seq"] = d.get("seq", 0) + 1
            n, who, now = d["seq"], d.get("viewer") or "you", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

            def comment(body, extra=None):
                return {"id": f"PRRC_fake{n}", "db": n, "author": who, "body": body, "at": now,
                        "url": f"https://github.com/fake/pull/c{n}", "commit": "", "originalCommit": "", **(extra or {})}

            def pr_of(number):
                pr = d["prs"].get(str(number))
                if not pr:
                    raise Refused(f"no PR #{number}")
                return pr

            def thread_of(node):
                for pr in d["prs"].values():
                    for t in pr["threads"]:
                        if t["node"] == node:
                            return t
                raise Refused("no such thread")

            out = {}
            if op == "review":
                pr = pr_of(args["pr"])
                for i, th in enumerate(args.get("threads") or []):
                    pr["threads"].append({
                        "node": f"PRRT_fake{n}_{i}", "path": th["path"], "line": th["line"],
                        "startLine": th.get("startLine"), "originalLine": th["line"],
                        "originalStartLine": th.get("startLine"), "side": th.get("side") or "RIGHT", "subject": "LINE",
                        "outdated": False, "resolved": False, "canResolve": True, "canUnresolve": False,
                        "canReply": True, "comments": [comment(th["body"], {"commit": pr["head"], "originalCommit": pr["head"]})],
                    })
                pr["reviews"].append({"id": f"PRR_fake{n}", "author": who, "state": {"COMMENT": "COMMENTED",
                                      "APPROVE": "APPROVED", "REQUEST_CHANGES": "CHANGES_REQUESTED"}[args["event"]],
                                      "body": args.get("body") or "", "at": now, "url": ""})
                out = {"review": f"PRR_fake{n}"}
            elif op == "reply":
                t = thread_of(args["thread"])
                t["comments"].append(comment(args["body"]))
                out = {"comment": f"PRRC_fake{n}"}
            elif op in ("resolve", "unresolve"):
                t = thread_of(args["thread"])
                t.update(resolved=op == "resolve", canResolve=op != "resolve", canUnresolve=op == "resolve")
            elif op == "comment":
                pr_of(args["pr"])["comments"].append({k: v for k, v in comment(args["body"]).items()
                                                      if k in ("id", "author", "body", "at", "url")})
            else:
                raise Refused(f"unknown op {op}")
            d.setdefault("log", []).append({"op": op, "args": args, "at": now})
            self._save(d)
            return out


_MUTATIONS = {
    "review": ("mutation($input: AddPullRequestReviewInput!) { addPullRequestReview(input: $input) "
               "{ pullRequestReview { id } } }", "addPullRequestReview"),
    "reply": ("mutation($input: AddPullRequestReviewThreadReplyInput!) { addPullRequestReviewThreadReply(input: $input) "
              "{ comment { id } } }", "addPullRequestReviewThreadReply"),
    "resolve": ("mutation($input: ResolveReviewThreadInput!) { resolveReviewThread(input: $input) { thread { id } } }",
                "resolveReviewThread"),
    "unresolve": ("mutation($input: UnresolveReviewThreadInput!) { unresolveReviewThread(input: $input) { thread { id } } }",
                  "unresolveReviewThread"),
    "comment": ("mutation($input: AddCommentInput!) { addComment(input: $input) { commentEdge { node { id } } } }",
                "addComment"),
}


def _gh_input(op, args, pr):
    if op == "review":
        threads = []
        for t in args.get("threads") or []:
            th = {"path": t["path"], "line": t["line"], "side": t.get("side") or "RIGHT", "body": t["body"]}
            if t.get("startLine"):
                th.update(startLine=t["startLine"], startSide=t.get("side") or "RIGHT")
            threads.append(th)
        return {"pullRequestId": pr["id"], "event": args["event"], "body": args.get("body") or "",
                "commitOID": pr["head"], "threads": threads}
    if op == "reply":
        return {"pullRequestReviewThreadId": args["thread"], "body": args["body"]}
    if op in ("resolve", "unresolve"):
        return {"threadId": args["thread"]}
    if op == "comment":
        return {"subjectId": pr["id"], "body": args["body"]}
    raise Refused(f"unknown op {op}")


def _gh_mutate(op, args):
    pr = None
    if "pr" in args:
        pr = cached({args["pr"]}).get(args["pr"])
        if not pr or not pr.get("id"):
            raise Refused(f"PR #{args['pr']} isn't read yet")
    query, field = _MUTATIONS[op]
    body = json.dumps({"query": query, "variables": {"input": _gh_input(op, args, pr)}})
    r = subprocess.run(["gh", "api", "graphql", "--input", "-"], input=body, cwd=ctx.repo_cwd(),
                       capture_output=True, text=True, timeout=40)
    try:
        resp = json.loads(r.stdout or "{}")
    except ValueError:
        resp = {}
    errs = resp.get("errors") or []
    if r.returncode != 0 or errs or not (resp.get("data") or {}).get(field):
        msg = (errs[0].get("message") if errs else "") or (r.stderr or "").strip() or "GitHub refused"
        raise Refused(msg[:200])
    return resp["data"][field]


def refusal(req):
    """Why this request may not write to the real GitHub, or None. The fake never asks."""
    if os.environ.get("STACK_REVIEW_SANDBOX") == "1":
        return "the sandbox never writes to GitHub — set STACK_REVIEW_GH_FAKE"
    who = getattr(req, "_actor", None)
    if who != "browser":
        return f"GitHub writes come from your browser, not {who or 'an unknown caller'}"
    if (req.headers.get("X-Stack-Via") or "") not in ("key", "click", "menu", "palette"):
        return "GitHub writes need a keypress or a click"
    if req.headers.get("Sec-Fetch-Site") != "same-origin":
        return "GitHub writes come from the viewer's own page"
    return None


def mutate(op, args, req=None, queued=False):
    """Run one review mutation. req is the HTTP request that asked (its gesture is checked); a
    queued reply passes queued=True — its gesture was checked when it was queued."""
    fake = _fake()
    if fake:
        return fake.mutate(op, args)
    if os.environ.get("STACK_REVIEW_SANDBOX") == "1":
        raise Refused("the sandbox never writes to GitHub")
    if not queued:
        why = refusal(req)
        if why:
            raise Refused(why)
    ctx.log(f"ghreview: {op} {json.dumps({k: v for k, v in args.items() if k != 'body'})[:200]}")
    return _gh_mutate(op, args)
