# srv/sync.py — fork-staleness (the "N behind" badge) + the unpublished-root sync.
#   GET  /sync?branch=X    one branch's staleness vs origin/main
#   GET  /syncs?branch=…   batch staleness for many branches in one round-trip
#   POST /sync {branch}    rebase an unpublished root onto fresh origin/main
import json
from urllib.parse import parse_qs
from concurrent.futures import ThreadPoolExecutor

from . import ctx


def state(branch):
    """Fork-staleness of a branch vs origin/main — the signal behind the viewer's
    "N behind" badge.
      behind    — commits on origin/main not yet in this branch (two-dot count,
                  `git rev-list --count <branch>..origin/main`). >0 means the fork
                  point is stale, so GitHub-Desktop two-dot diffs inflate by ~this.
      syncable  — safe to auto-rebase onto origin/main with NO force-push. True
                  only for a root off main (parent==main) that is unpublished (no
                  remote-tracking ref). Rebasing a *published* branch rewrites
                  pushed commits (→ force-push); rebasing a *stacked* branch
                  detaches it from its parent (→ that's a restack, not a sync).
                  Neither is offered here — `why` explains the refusal.
    Pure inspection: no fetch, no mutation."""
    if not branch:
        return {"branch": "", "behind": 0, "syncable": False, "why": "no branch"}
    raw = ctx.run(["git", "rev-list", "--count", f"{branch}..origin/main"]).stdout.strip()
    try:
        behind = int(raw)
    except ValueError:
        behind = 0   # origin/main absent or bad ref → treat as up-to-date (no badge)
    parent = ctx.run(["git", "config", f"stack-branch.{branch}.parent"]).stdout.strip() or "main"
    # published = a remote-tracking ref for THIS branch exists on any remote. Suffix-
    # match (not a `refs/remotes/*/X` glob) so slashed names like goal/foo and
    # multiple remotes both resolve. More reliable than upstream config, which the
    # repo's branch.autoSetupMerge=simple can silently point at origin/main.
    remotes = ctx.run(["git", "for-each-ref", "--format=%(refname)", "refs/remotes/"]).stdout.splitlines()
    published = any(r.endswith("/" + branch) for r in remotes)
    why = ""
    if behind == 0:
        why = "up to date with origin/main"
    elif parent != "main":
        why = f"stacked on {parent} — needs a restack, not a sync"
    elif published:
        why = "published — rebasing would rewrite pushed commits"
    # deploy-critical files changed on origin/main that this branch is missing. The
    # pre-push hook (.git/hooks/pre-push) HARD-BLOCKS the push (exit 1) when the branch
    # is behind AND any of these changed — plain "behind" only warns. Same pathspec list
    # as the hook, so the UI can show "push blocked, rebase first" before you try.
    deploy_critical = []
    if behind > 0:
        deploy_critical = [f for f in ctx.run([
            "git", "diff", "--name-only", f"{branch}..origin/main", "--",
            "k8s/charts/loops/values.staging.yaml",
            "k8s/charts/loops/values.production.yaml",
            "packages/prisma/migrations/*",
            "clickhouse/migrations/*",
            "jobs.ts",
            "jobs/index.ts",
            ".env.template",
        ]).stdout.splitlines() if f]
    return {"branch": branch, "behind": behind, "parent": parent, "published": published,
            "syncable": behind > 0 and parent == "main" and not published, "why": why,
            "deployCritical": deploy_critical}


def get_one(req, u):
    req._send(200, json.dumps(state(parse_qs(u.query).get("branch", [""])[0])))


def get_many(req, u):
    # BATCH fork-staleness: all branches in ONE round-trip, so the graph/rail badges
    # don't fan out N per-node /sync requests into the browser's ~6-connection-per-
    # origin limit (which serializes them into a load waterfall).
    bs = [b for b in parse_qs(u.query).get("branch", []) if b]
    with ThreadPoolExecutor(max_workers=8) as ex:   # state() shells git (GIL released) → real parallelism
        states = dict(zip(bs, ex.map(state, bs)))
    req._send(200, json.dumps(states))


def post_sync(req, raw):
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    st = state(branch)   # re-check server-side: never rebase a published/stacked branch on a stale client view
    if not st.get("syncable"):
        req._send(409, json.dumps({"ok": False, "err": st.get("why", "not syncable")}))
        return
    r = ctx.run(["git", "rebase", "origin/main", branch])   # checks out branch; git refuses if the tree is dirty
    req._send(200 if r.returncode == 0 else 500,
              json.dumps({"ok": r.returncode == 0, "out": r.stdout, "err": r.stderr}))
