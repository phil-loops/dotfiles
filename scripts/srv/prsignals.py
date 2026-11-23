# srv/prsignals.py — GET /pr-signals: what GitHub says about each of my open PRs beyond its state, for the
# home's row icons — CI check counts by outcome, unresolved review threads, comments, approvals, and the branches
# above it in a native GitHub stack that a merge would strand. One GraphQL
# search of my open PRs on origin (~1 s), stale-while-revalidate at 60 s; a cold read answers {} and fills behind.
import json
import threading
import time

from . import ctx, openprs

TTL = 60.0
QUERY = """query($q:String!){ search(query:$q, type:ISSUE, first:100){ nodes{ ... on PullRequest { number mergeable
  latestReviews(first:30){nodes{state author{login}}}
  reviewThreads(first:100){nodes{isResolved}}
  comments{totalCount}
  commits(last:1){nodes{commit{statusCheckRollup{contexts(first:1){
    checkRunCountsByState{state count} statusContextCountsByState{state count}}}}}}
}}}}"""

# Asked apart from QUERY: Phil stacks PRs natively only now and then, and nothing else here may depend on it —
# if this one fails, the row icons still come back.
STACK_QUERY = """query($q:String!){ search(query:$q, type:ISSUE, first:100){ nodes{ ... on PullRequest { number
  stack{ entries(first:50){ nodes{ position pullRequest{ number state headRefName } } } }
}}}}"""

# a check run's or status context's state, bucketed the way GitHub's checks summary draws it; unlisted states
# (SKIPPED, NEUTRAL, COMPLETED, STALE) count nowhere
BUCKET = {"SUCCESS": "pass",
          "FAILURE": "fail", "ERROR": "fail", "TIMED_OUT": "fail", "CANCELLED": "fail",
          "STARTUP_FAILURE": "fail", "ACTION_REQUIRED": "fail",
          "IN_PROGRESS": "running",
          "QUEUED": "queued", "PENDING": "queued", "WAITING": "queued", "REQUESTED": "queued", "EXPECTED": "queued"}

_lock = threading.Lock()
_cache = {}    # repo -> {"at": monotonic, "data": {number: signals}}
_busy = set()  # repos with a sweep in flight


def signals(node):
    """One PR's signals from its search node."""
    checks = {"pass": 0, "fail": 0, "running": 0, "queued": 0}
    commits = ((node.get("commits") or {}).get("nodes") or [{}])
    ctxs = ((((commits[-1] if commits else {}).get("commit") or {}).get("statusCheckRollup") or {}).get("contexts") or {})
    for row in (ctxs.get("checkRunCountsByState") or []) + (ctxs.get("statusContextCountsByState") or []):
        b = BUCKET.get(row.get("state"))
        if b:
            checks[b] += row.get("count") or 0
    reviews = (node.get("latestReviews") or {}).get("nodes") or []
    return {
        "checks": checks,
        "threads": sum(1 for t in (node.get("reviewThreads") or {}).get("nodes") or [] if not t.get("isResolved")),
        "comments": ((node.get("comments") or {}).get("totalCount")) or 0,
        "approvals": sum(1 for r in reviews if r.get("state") == "APPROVED"),
        "changesRequested": any(r.get("state") == "CHANGES_REQUESTED" for r in reviews),
        "conflicts": node.get("mergeable") == "CONFLICTING",
    }


def parse(stdout):
    """{number: signals} from the search's JSON; None when it isn't an answer."""
    try:
        nodes = json.loads(stdout)["data"]["search"]["nodes"]
    except (ValueError, KeyError, TypeError):
        return None
    return {str(n["number"]): signals(n) for n in nodes if n and n.get("number")}


def above(stdout):
    """{number: [the head branch of each open PR above it in its native GitHub stack]}; {} when it isn't an answer."""
    try:
        nodes = json.loads(stdout)["data"]["search"]["nodes"]
    except (ValueError, KeyError, TypeError):
        return {}
    out = {}
    for n in nodes:
        entries = (((n or {}).get("stack") or {}).get("entries") or {}).get("nodes") or []
        at = next((e.get("position") for e in entries if (e.get("pullRequest") or {}).get("number") == n.get("number")), None)
        heads = [e["pullRequest"]["headRefName"] for e in sorted(entries, key=lambda e: e.get("position") or 0)
                 if at is not None and (e.get("position") or 0) > at and (e.get("pullRequest") or {}).get("state") == "OPEN"]
        if heads:
            out[str(n["number"])] = heads
    return out


def strands(heads):
    """Which of `heads` hold unpushed commits here, as [{branch, commits}]. When the PR below them in a native
    stack merges, GitHub rebases and force-pushes them, and those commits are left on the old history
    (2026-11-23, delete-user): they go out first."""
    from . import catchup
    counted = [{"branch": b, "commits": len(catchup.unpushed(b)[0])} for b in heads]
    return [c for c in counted if c["commits"]]


def _fetch(slug):
    q = f"q=repo:{slug} is:pr is:open author:@me"
    r = ctx.run(["gh", "api", "graphql", "-f", f"query={QUERY}", "-f", q], timeout=30)
    got = parse(r.stdout) if r.returncode == 0 else None
    if got:
        r = ctx.run(["gh", "api", "graphql", "-f", f"query={STACK_QUERY}", "-f", q], timeout=30)
        for number, heads in (above(r.stdout) if r.returncode == 0 else {}).items():
            if number in got:
                got[number]["above"] = heads
    return got


def _refresh(repo, slug):
    try:
        got = _fetch(slug)
        if got is not None:
            with _lock:
                _cache[repo] = {"at": time.monotonic(), "data": got}
    finally:
        _busy.discard(repo)


def current():
    """{number: signals} for my open PRs on origin; {} until the first sweep lands, the last good one after."""
    repo = ctx.repo_cwd()
    with _lock:
        ent = _cache.get(repo)
        stale = not ent or time.monotonic() - ent["at"] >= TTL
        if stale and repo not in _busy:
            slug = openprs.origin_slug()
            if slug:
                _busy.add(repo)
                threading.Thread(target=_refresh, args=(repo, slug), daemon=True).start()
        data = dict(ent["data"]) if ent else {}
    # what GitHub said a minute ago about who sits above; what is unpushed is read now
    return {n: {**{k: v for k, v in sig.items() if k != "above"}, "strands": strands(sig.get("above") or [])}
            for n, sig in data.items()}


def get(req):   # GET /pr-signals
    req._send(200, json.dumps(current()))
