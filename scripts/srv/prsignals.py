# srv/prsignals.py — GET /pr-signals: what GitHub says about each of my open PRs beyond its state, for the
# home's row icons — CI check counts by outcome, unresolved review threads, comments, approvals. One GraphQL
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


def _fetch(slug):
    r = ctx.run(["gh", "api", "graphql", "-f", f"query={QUERY}",
                 "-f", f"q=repo:{slug} is:pr is:open author:@me"], timeout=30)
    return parse(r.stdout) if r.returncode == 0 else None


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
        return dict(ent["data"]) if ent else {}


def get(req):   # GET /pr-signals
    req._send(200, json.dumps(current()))
