# srv/review.py — the review surface: the forest model, per-node file list + diffs,
# commit log, branch purpose, blessing, and the squash/prep-for-push actions.
#   GET  /model?branch=X    the forest model JSON (stack-forest), cached on model_sig
#   GET  /node?branch=X     a node's file list (stack-forest --node)
#   GET  /purpose?branch=X  branch purpose/thesis (read; ?generate=1 opts into token spend)
#   GET  /file?branch&path  a file's contents on a ref (git show)
#   GET  /commits?branch=X  branch history: own commits (own:true) + ancestors (own:false)
#   GET  /commit-diff?sha=X one commit's changed files + patches (git show)
#   POST /bless {branch,file}    mark file(s) reviewed (stack-bless)
#   POST /purpose {branch,text}  save a thesis as the branch description
#   POST /squash {branch}        collapse parent..branch into unstaged working-tree changes
#   POST /prep {branch}          prep-for-push: squash unpushed → one, then oxfmt
import os
import json
import tempfile
import re
import hashlib
import threading
from urllib.parse import parse_qs

from . import ctx, picker

# (repo, branch) -> {"sig", "branches", "out"} — validated per-FOREST (only its own ref
# tips + config/ledger mtimes), so an unrelated worktree's commit no longer busts every
# forest's model, and switching between forests stays warm instead of clear()-on-miss.
_mcache = {}
_MCACHE_MAX = 8
_mcache_lock = threading.Lock()


# the config keys the /model payload is actually built from (stack-forest's structure
# reads + _enrich's description/interest grafts). The sig hashes ONLY these lines —
# whole-file config mtime busted every forest's cache on any unrelated write (gates
# verdicts, shelve/focus/usage counters churn it constantly with live sessions), so
# /model rebuilt ~1s on nearly every fetch.
_MODEL_CFG = re.compile(
    r"^(stack\.main-branch="
    r"|branch\.[^=]+\.description="
    r"|branch\.[^=]+\.stack-(parent|requires|project)="
    r"|stack-branch\.[^=]+\.(parent|requires|project)="
    r"|stack-project\.[^=]+\.(branch|archived|interest|ticket)=)")


def _forest_sig(branches):
    main = ctx.run(["git", "config", "stack.main-branch"]).stdout.strip() or "main"
    pats = [f"refs/heads/{b}" for b in branches]
    pats += [f"refs/heads/{main}", f"refs/remotes/origin/{main}"]
    refs = ctx.run(["git", "for-each-ref", "--format=%(refname) %(objectname)", *pats]).stdout
    gd = ctx.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"]).stdout.strip()
    cfg = "\n".join(ln for ln in ctx.run(["git", "config", "--local", "--list"]).stdout.splitlines()
                    if _MODEL_CFG.match(ln))

    def mt(p):
        try:
            return os.path.getmtime(p)
        except OSError:
            return 0
    stamp = (refs + cfg
             + str(mt(os.path.join(gd, "stack-blessed.json")))
             + str(mt(os.path.join(gd, "stack-blessed-contrib.json"))))
    return hashlib.sha1(stamp.encode()).hexdigest()


def _known_forest_name(name):
    """A real branch, or a name some stack config knows — stack-forest fabricates a
    one-node forest for ANY string, so /model must gate or /forests/<typo> renders a ghost."""
    if not name:
        return False
    if ctx.run(["git", "rev-parse", "--verify", "-q", f"refs/heads/{name}"]).returncode == 0:
        return True
    if ctx.run(["git", "config", "--get-all", f"stack-project.{name}.branch"]).stdout.strip():
        return True
    tags = {}
    for line in ctx.run(["git", "config", "--get-regexp", r"^stack-branch\..*\.project$"]).stdout.splitlines():
        key, _, val = line.partition(" ")
        tags[key[len("stack-branch."):-len(".project")]] = val.strip()
    for line in ctx.run(["git", "config", "--get-regexp", r"^branch\..*\.stack-project$"]).stdout.splitlines():
        key, _, val = line.partition(" ")
        tags[key[len("branch."):-len(".stack-project")]] = val.strip()
    return name in tags.values()


def model(req, u):
    branch = parse_qs(u.query).get("branch", [""])[0]
    ck = (ctx.repo_cwd(), branch)
    with _mcache_lock:
        ent = _mcache.get(ck)
    pre_sig = _forest_sig(ent["branches"]) if ent else None
    if ent and ent["sig"] == pre_sig:
        req._send(200, ent["out"])
        return
    if not _known_forest_name(branch):
        req._send(404, json.dumps({"error": f"no branch or forest named {branch!r}"}))
        return
    guard = ctx.model_sig()   # what the build is about to read, fingerprinted BEFORE it reads it
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-forest"), branch])
    if r.returncode != 0:
        req._send(500, json.dumps({"error": r.stderr}))
    else:
        out = _enrich(r.stdout, branch)
        try:
            branches = list((json.loads(out) or {}).get("nodes") or {})
        except ValueError:
            branches = []
        # A mutation landing mid-build (a /contract dropping a node) leaves `out` describing the
        # repo as it was BEFORE it — and a post-build sig then certifies that stale forest for
        # good, since every later check re-measures the same settled state and matches. That
        # froze a contracted branch on the map until the server was bounced (2026-07-21). An
        # empty sig can never equal a fresh one, so the next request rebuilds instead.
        sig = _forest_sig(branches) if ctx.model_sig() == guard else ""
        with _mcache_lock:
            _mcache.pop(ck, None)
            _mcache[ck] = {"sig": sig, "branches": branches, "out": out}
            while len(_mcache) > _MCACHE_MAX:
                _mcache.pop(next(iter(_mcache)))
        req._send(200, out)


def _enrich(raw, branch):
    # graft what the forest views want without an N-fetch round trip:
    #   description    — the branch's one-line purpose (git branch description), per node
    #   mergeRank      — deterministic merge-order depth, per node (handy for layout/labels)
    #   mergeOrder     — the canonical total order as a flat array, top-level. Consume this
    #                    VERBATIM: sorting nodes by mergeRank client-side reintroduces drift
    #                    (the rank ties, and the tie-break is the stack-project DECLARED order,
    #                    which the nodes map does not preserve). The array bakes the tie-break in.
    # All from stack-merge-rank — the single topo authority shared with stack-pr-body.
    # Best-effort: malformed JSON or a missing field just passes through untouched.
    try:
        data = json.loads(raw)
    except ValueError:
        return raw
    ranks, order = {}, []
    rk = ctx.run([os.path.join(ctx.SCRIPTS, "stack-merge-rank"), branch])
    if rk.returncode == 0:
        try:
            mr = json.loads(rk.stdout) or {}
            ranks, order = mr.get("rank", {}), mr.get("order", [])
        except ValueError:
            pass
    for bid, meta in (data.get("nodes") or {}).items():
        if not isinstance(meta, dict):
            continue
        desc = ctx.run(["git", "config", f"branch.{bid}.description"]).stdout.strip()
        if desc:
            meta["description"] = desc
        if bid in ranks:
            meta["mergeRank"] = ranks[bid]
    proj = picker._project_of(branch)
    if proj:
        iv = ctx.run(["git", "config", f"stack-project.{proj}.interest"]).stdout.strip()
        if iv.lstrip("-").isdigit() and int(iv) > 0:
            data["interest"] = int(iv)
        tv = ctx.run(["git", "config", f"stack-project.{proj}.ticket"]).stdout.strip()
        if tv:
            data["ticket"] = tv.lower()
    if order:
        data["mergeOrder"] = order
    return json.dumps(data)


def _is_convergence(branch, stdout):
    # A convergence node: a real fan-in branch (has `requires`) whose OWN contribution
    # (parent...node) is empty — it never merges, it converges several bases into one view.
    try:
        if (json.loads(stdout) or {}).get("files"):
            return False  # has its own contribution — an ordinary node, not a convergence
    except ValueError:
        return False
    return bool(ctx.run(["git", "config", "--get-all", f"branch.{branch}.stack-requires"]).stdout.strip()
                or ctx.run(["git", "config", "--get-all", f"stack-branch.{branch}.requires"]).stdout.strip())


def node(req, u):
    q = parse_qs(u.query)
    branch = q.get("branch", [""])[0]
    base = q.get("base", [""])[0]
    # the ghost ✦<project> node diffs main..refs/stack/<project>-integration — an ephemeral octopus
    # of the project's leaves. Branches move, so rebuild it on select before diffing; stack-forest
    # --node handles the raw ref + --base main exactly like a real node's parent..branch.
    if branch.startswith("refs/stack/") and branch.endswith("-integration"):
        project = branch[len("refs/stack/"):-len("-integration")]
        ctx.run([os.path.join(ctx.SCRIPTS, "stack-integrate"), project, "--check"])
        base = base or "main"
    args = [os.path.join(ctx.SCRIPTS, "stack-forest"), "--node", branch]
    if base:
        args += ["--base", base]
    r = ctx.run(args)
    # A convergence node renders blank otherwise (its own parent...node diff is empty). Diff it
    # against the base instead (base...node, base=main) so it shows the WHOLE assembled feature —
    # a "review it all at once" surface — rather than a navigable blank.
    if r.returncode == 0 and not base and _is_convergence(branch, r.stdout):
        r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-forest"), "--node", branch, "--base", "main"])
    req._send(200 if r.returncode == 0 else 500,
              r.stdout if r.returncode == 0 else json.dumps({"branch": branch, "files": []}))


def pr_body(req, u):
    # draft a GitHub PR description that frames the branch in its forest (what + where-it-fits).
    # Spends tokens (stack-pr-body → claude) — only ever hit from an explicit "draft PR" click.
    branch = parse_qs(u.query).get("branch", [""])[0]
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-pr-body"), branch])
    req._send(200 if r.returncode == 0 else 500,
              r.stdout if r.returncode == 0 else "_(draft failed — see server log)_",
              "text/plain; charset=utf-8")


def plan_section(req, u):
    # the forest-plan block for a commit body — where this branch sits in its project. Recomputed
    # from stack config alone: free, no model call (unlike pr_body's summary). Feeds the message
    # editor's "recompute plan" button.
    branch = parse_qs(u.query).get("branch", [""])[0]
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-commit-body"), branch, "--section"])
    req._send(200 if r.returncode == 0 else 500,
              r.stdout if r.returncode == 0 else "",
              "text/plain; charset=utf-8")


def purpose_get(req, u):
    q = parse_qs(u.query)
    args = [os.path.join(ctx.SCRIPTS, "stack-purpose")]
    if q.get("generate", ["0"])[0] == "1":   # opt-in token spend, only on ask
        args.append("--generate")
    args.append(q.get("branch", [""])[0])
    r = ctx.run(args)
    req._send(200 if r.returncode == 0 else 500,
              r.stdout if r.returncode == 0 else json.dumps({"thesis": "", "enables": "", "source": "none"}))


def forest_purposes(req, u):
    # one shot for the Forests-row hover card: every member branch + its one-line purpose
    # (git branch description), so "what's going on in here" reads at a glance without N fetches.
    project = parse_qs(u.query).get("project", [""])[0]
    members = ctx.run(["git", "config", "--get-all", f"stack-project.{project}.branch"]).stdout.splitlines()
    out, seen = [], set()
    for b in (m.strip() for m in members):
        if not b or b in seen:
            continue
        seen.add(b)
        thesis = ctx.run(["git", "config", f"branch.{b}.description"]).stdout.strip()
        out.append({"branch": b, "thesis": thesis})
    req._send(200, json.dumps(out))


def file(req, u):
    q = parse_qs(u.query)
    branch, path = q.get("branch", [""])[0], q.get("path", [""])[0]
    r = ctx.run(["git", "show", f"{branch}:{path}"])
    req._send(200 if r.returncode == 0 else 404,
              r.stdout if r.returncode == 0 else "(file not found on this ref)",
              "text/plain; charset=utf-8")


def commits(req, u):
    # GitHub-Desktop-style history: the branch's OWN commits first (own:true), then the
    # ancestor history it forked from (own:false) so the list reads like a real timeline —
    # not just the parent..branch delta. `own` membership is the rev-list of parent..branch.
    branch = parse_qs(u.query).get("branch", [""])[0]
    parent = (ctx.run(["git", "config", f"branch.{branch}.stack-parent"]).stdout.strip()
              or ctx.run(["git", "config", f"stack-branch.{branch}.parent"]).stdout.strip() or "main")
    own = set(ctx.run(["git", "rev-list", f"{parent}..{branch}"]).stdout.split())
    fmt = "%H\x1f%h\x1f%s\x1f%an\x1f%ad"   # \x1f = unit-sep: safe field split (subjects can hold anything)
    out = ctx.run(["git", "log", branch, f"--format={fmt}", "--date=short", "-n", "80"]).stdout
    rows = []
    for ln in out.splitlines():
        p = ln.split("\x1f")
        if len(p) >= 3:
            rows.append({"sha": p[1], "subject": p[2],
                         "author": p[3] if len(p) > 3 else "", "date": p[4] if len(p) > 4 else "",
                         "own": p[0] in own})
    req._send(200, json.dumps(rows))


_CDIFF_HDR = re.compile(r"^diff --git a/(.+?) b/(.+)$")


def commit_diff(req, u):
    # one commit's changed files + patches (git show <sha>), in the same FileDiff shape the
    # node view renders — so the history list can expand a commit inline. Read-only: these are
    # historical commits, nothing to bless. Diffed against the commit's first parent.
    sha = parse_qs(u.query).get("sha", [""])[0]
    counts = {}
    for ln in ctx.run(["git", "show", "--numstat", "--format=", sha]).stdout.splitlines():
        p = ln.split("\t")
        if len(p) == 3:
            counts[p[2]] = (0 if p[0] == "-" else int(p[0]), 0 if p[1] == "-" else int(p[1]))
    full = ctx.run(["git", "show", "-p", "--format=", sha]).stdout
    files = []
    for ch in re.split(r"(?m)^(?=diff --git )", full):
        if not ch.startswith("diff --git "):
            continue
        m = _CDIFF_HDR.match(ch.splitlines()[0])
        if not m:
            continue
        path = m.group(2)
        add, dele = counts.get(path, (0, 0))
        files.append({"path": path, "status": "clean", "add": add, "del": dele,
                      "patch": ch.rstrip("\n") + "\n"})
    req._send(200, json.dumps({"sha": sha, "files": files}))


# --- POST ---

def bless(req, raw):
    d = json.loads(raw or "{}")
    args = [os.path.join(ctx.SCRIPTS, "stack-bless"), d.get("branch", "")]
    f = d.get("file")
    if f and f != ".":
        args += ["--file", f]
    if d.get("unbless"):
        args.append("--unbless")
    r = ctx.run(args)
    req._send(200 if r.returncode == 0 else 500,
              json.dumps({"ok": r.returncode == 0, "out": r.stdout, "err": r.stderr}))


def frozen_origin_set(req, raw):
    # mark/unmark a branch's origin as deliberately frozen (stack-branch.<b>.frozen-origin):
    # the pushed PR stays the review artifact while local carries the restacked truth.
    d = json.loads(raw or "{}")
    b = d.get("branch", "")
    if not b:
        req._send(400, "{}")
        return
    if d.get("value"):
        r = ctx.run(["git", "config", f"stack-branch.{b}.frozen-origin", "1"])
        ok = r.returncode == 0
    else:
        r = ctx.run(["git", "config", "--unset", f"stack-branch.{b}.frozen-origin"])
        ok = r.returncode in (0, 5)  # 5 = already unset
    req._send(200 if ok else 500, "{}")


def purpose_set(req, raw):
    d = json.loads(raw or "{}")
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-purpose"), "--set", d.get("text", ""), d.get("branch", "")])
    req._send(200 if r.returncode == 0 else 500, r.stdout if r.returncode == 0 else "{}")


def notes_get(req, u):
    # per-branch test/repro notes (the stack-notes sidecar) — how to recreate the verified state
    branch = parse_qs(u.query).get("branch", [""])[0]
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-notes"), "--json", branch])
    req._send(200 if r.returncode == 0 else 500,
              r.stdout if r.returncode == 0 else json.dumps({"branch": branch, "markdown": "", "mtime": 0}))


def notes_set(req, raw):
    # ctx.run has no stdin path, so the note body travels via a temp file (--set-file; empty deletes)
    d = json.loads(raw or "{}")
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
        f.write(d.get("markdown", ""))
        tmp = f.name
    try:
        r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-notes"), "--set-file", tmp, d.get("branch", "")])
    finally:
        os.unlink(tmp)
    req._send(200 if r.returncode == 0 else 500, json.dumps({"ok": r.returncode == 0}))


def _plan_defaults():
    try:
        return json.loads(ctx.run(["python3", os.path.join(ctx.SCRIPTS, "stack_facts.py"), "plan-defaults"]).stdout)
    except Exception:
        return {"template": "", "step": ""}


def _proj_cfg_raw(project, key):
    # raw read — a template's leading indent + internal newlines are load-bearing (git config appends
    # one trailing newline of its own; drop only that). Mirrors stack_facts._proj_cfg.
    r = ctx.run(["git", "config", f"stack-project.{project}.{key}"])
    if r.returncode != 0:
        return ""
    return r.stdout[:-1] if r.stdout.endswith("\n") else r.stdout


def plan_template_get(req, u):
    # GET /plan-template?project=X → the per-project body template + step line (edited once, carried
    # to every child), plus the built-in defaults the editor prefills / falls back to.
    project = parse_qs(u.query).get("project", [""])[0]
    if not project:
        return req._send(400, json.dumps({"error": "no project"}))
    req._send(200, json.dumps({
        "project": project,
        "template": _proj_cfg_raw(project, "plan-template"),
        "step": _proj_cfg_raw(project, "plan-step"),
        "defaults": _plan_defaults(),
    }))


def plan_template_set(req, raw):
    # POST /plan-template {project, template, step} → persist the template. Empty or default-equal
    # values are UNSET, so config stays clean and render falls back to the built-in default.
    d = json.loads(raw or "{}")
    project = (d.get("project") or "").strip()
    if not project:
        return req._send(400, json.dumps({"error": "no project"}))
    defaults = _plan_defaults()
    for key, field in (("plan-template", "template"), ("plan-step", "step")):
        val = d.get(field)
        cfgkey = f"stack-project.{project}.{key}"
        if not val or val == defaults.get(field):
            ctx.run(["git", "config", "--unset", cfgkey])
        else:
            ctx.run(["git", "config", cfgkey, val])
    req._send(200, json.dumps({"ok": True}))


def plan_preview(req, u):
    # GET /plan-preview?branch=X → the rendered plan block for that branch, so the template editor
    # shows the live effect with the volatile facts (#PR, [this branch], position) filled in.
    branch = parse_qs(u.query).get("branch", [""])[0]
    if not branch:
        return req._send(400, json.dumps({"error": "no branch"}))
    r = ctx.run(["python3", os.path.join(ctx.SCRIPTS, "stack_facts.py"), "plan", branch])
    req._send(200, json.dumps({"plan": r.stdout.rstrip("\n")}))


def plan_steps(req, u):
    # GET /plan-steps?branch=X → the forest's steps in merge order, structured for per-step editing:
    # each carries its branch, effective one-line story (job), the raw stored `.story` override (if
    # any), whether it already landed, and which one is [this branch]. Feeds the plan-step editor —
    # editing a line writes that step's OWN branch, so the story is durable past this branch's merge.
    branch = parse_qs(u.query).get("branch", [""])[0]
    if not branch:
        return req._send(400, json.dumps({"error": "no branch"}))
    r = ctx.run(["python3", os.path.join(ctx.SCRIPTS, "stack_facts.py"), "steps", branch])
    try:
        f = json.loads(r.stdout)
    except Exception:
        return req._send(500, json.dumps({"steps": []}))
    steps = [{"n": s.get("n"), "branch": s.get("branch"), "job": s.get("job"),
              "story": s.get("story", ""), "landed": s.get("landed", False), "me": s.get("me", False)}
             for s in f.get("plan", [])]
    req._send(200, json.dumps({"branch": branch, "project": f.get("project"), "steps": steps}))


def story_set(req, raw):
    # POST /story {branch, text} → set (or, on empty text, unset → revert to the commit-subject
    # gloss) a branch's durable merge story. job_of() prefers it, so the plan renders it on EVERY
    # branch in the forest and it survives this branch's merge.
    d = json.loads(raw or "{}")
    branch = (d.get("branch") or "").strip()
    text = (d.get("text") or "").strip()
    if not branch:
        return req._send(400, json.dumps({"ok": False, "err": "no branch"}))
    key = f"stack-branch.{branch}.story"
    if text:
        ctx.run(["git", "config", key, text])
    else:
        ctx.run(["git", "config", "--unset", key])
    req._send(200, json.dumps({"ok": True, "branch": branch, "story": text}))


def interest_bump(req, raw):
    # Promote/demote a forest's manual interest level (stack-project.<p>.interest). Body carries
    # {project, delta} (+1 promote / -1 demote) or {project, value} (absolute); {branch} resolves
    # to its project. Clamped ≥0; 0 unsets. Orders the Forests home; purely Phil's signal.
    d = json.loads(raw or "{}")
    proj = d.get("project", "") or (picker._project_of(d["branch"]) if d.get("branch") else "")
    if not proj:
        return req._send(400, json.dumps({"ok": False, "error": "no project for interest"}))
    key = f"stack-project.{proj}.interest"
    cur = ctx.run(["git", "config", key]).stdout.strip()
    cur = int(cur) if cur.lstrip("-").isdigit() else 0
    nxt = int(d["value"]) if "value" in d else cur + int(d.get("delta", 0))
    nxt = max(0, nxt)
    if nxt > 0:
        ctx.run(["git", "config", key, str(nxt)])
    else:
        ctx.run(["git", "config", "--unset", key])
    req._send(200, json.dumps({"ok": True, "project": proj, "interest": nxt}))


def ticket_set(req, raw):
    # Tie a forest to its Linear ticket (stack-project.<p>.ticket) — commit scopes and the
    # merge story then read type(loo-####): instead of the project name. Body carries
    # {project, ticket} ({branch} resolves to its project); blank ticket unsets.
    d = json.loads(raw or "{}")
    proj = d.get("project", "") or (picker._project_of(d["branch"]) if d.get("branch") else "")
    if not proj:
        return req._send(400, json.dumps({"ok": False, "error": "no project for ticket"}))
    ticket = (d.get("ticket") or "").strip().upper()
    if ticket and not re.fullmatch(r"[A-Za-z]+-\d+", ticket):
        return req._send(400, json.dumps({"ok": False, "error": "ticket must look like LOO-1234"}))
    key = f"stack-project.{proj}.ticket"
    if ticket:
        ctx.run(["git", "config", key, ticket])
    else:
        ctx.run(["git", "config", "--unset", key])
    req._send(200, json.dumps({"ok": True, "project": proj, "ticket": ticket.lower()}))


def shelve(req, raw):
    # Mark/unmark a forest deliberately paused (stack-project.<p>.shelved true). Phil's own
    # signal — a shelved forest leaves the active bands for the shelved fold until unshelved,
    # no matter its PR/merge state.
    d = json.loads(raw or "{}")
    proj = d.get("project", "")
    if not proj:
        return req._send(400, json.dumps({"ok": False, "error": "no project"}))
    key = f"stack-project.{proj}.shelved"
    on = bool(d.get("on", True))
    if on:
        ctx.run(["git", "config", key, "true"])
    else:
        ctx.run(["git", "config", "--unset", key])
    req._send(200, json.dumps({"ok": True, "project": proj, "shelved": on}))


def _focus_git(repo, *args):
    # Focus rank lives in each project's OWN repo config; the lane can span repos, so target the
    # entry's repo explicitly rather than the request's cwd (unknown repo → default cwd).
    path = ctx.REPOS.get(repo) if repo else None
    base = ["git", "-C", path] if path else ["git"]
    return ctx.run(base + list(args))


def focus_set(req, raw):
    # Pin/unpin a forest to the focus lane, or reorder the whole lane (stack-project.<p>.focus N,
    # 1-based). {order:[{repo,project}...]} rewrites ranks 1..N in one shot (the drag-reorder path);
    # {repo,project,on} toggles one pin — on appends past the current max rank, off unsets it.
    d = json.loads(raw or "{}")
    if isinstance(d.get("order"), list):
        for i, e in enumerate(d["order"]):
            proj, repo = e.get("project", ""), e.get("repo", "")
            if proj:
                _focus_git(repo, "config", f"stack-project.{proj}.focus", str(i + 1))
        return req._send(200, json.dumps({"ok": True, "count": len(d["order"])}))
    proj, repo = d.get("project", ""), d.get("repo", "")
    if not proj:
        return req._send(400, json.dumps({"ok": False, "error": "no project"}))
    key = f"stack-project.{proj}.focus"
    if d.get("on", True):
        lines = _focus_git(repo, "config", "--get-regexp",
                           r"^stack-project\..*\.focus$").stdout.splitlines()
        ranks = [int(v) for v in (ln.rpartition(" ")[2] for ln in lines)
                 if v.strip().lstrip("-").isdigit()]
        _focus_git(repo, "config", key, str((max(ranks, default=0)) + 1))
        return req._send(200, json.dumps({"ok": True, "project": proj, "focus": True}))
    _focus_git(repo, "config", "--unset", key)
    req._send(200, json.dumps({"ok": True, "project": proj, "focus": False}))


def tier_set(req, raw):
    # Set a forest's conviction tier (stack-project.<p>.tier ∈ committed|trying|spike); an empty/
    # absent tier unsets → untriaged (the triage zone). Repo-scoped like interest.
    d = json.loads(raw or "{}")
    proj = d.get("project", "")
    if not proj:
        return req._send(400, json.dumps({"ok": False, "error": "no project"}))
    key = f"stack-project.{proj}.tier"
    tier = d.get("tier", "")
    if tier in ("committed", "trying", "spike"):
        ctx.run(["git", "config", key, tier])
    else:
        ctx.run(["git", "config", "--unset", key])
        tier = None
    req._send(200, json.dumps({"ok": True, "project": proj, "tier": tier}))


def _scratch_worktree_for(branch):
    # stack-open's scratch worktrees are DETACHED and record their branch in a stack-open-branch
    # marker; match it so open-in-nvim edits can be committed/discarded from the uncommitted rail.
    r = ctx.run(["git", "worktree", "list", "--porcelain"])
    if r.returncode != 0:
        return None
    for line in r.stdout.splitlines():
        if not line.startswith("worktree "):
            continue
        path = line[9:]
        gd = ctx.run(["git", "-C", path, "rev-parse", "--absolute-git-dir"]).stdout.strip()
        if not gd:
            continue
        try:
            if open(os.path.join(gd, "stack-open-branch")).read().strip() == branch:
                return path
        except OSError:
            pass
    return None


def _worktree_for_branch(branch):
    r = ctx.run(["git", "worktree", "list", "--porcelain"])
    if r.returncode != 0:
        return None
    wt_path = None
    for line in r.stdout.splitlines():
        if line.startswith("worktree "):
            wt_path = line[9:]
        elif line.startswith("branch refs/heads/") and line[18:] == branch:
            return wt_path
    return _scratch_worktree_for(branch)


def _dirty_paths_of(wt):
    st = ctx.run(["git", "-C", wt, "status", "--porcelain"]).stdout.splitlines()
    return {l[3:].split(" -> ", 1)[-1].strip().strip('"') for l in st if len(l) > 3}


def commit_dirty(req, raw):
    # {branch, message, path?} — path narrows the commit to ONE dirty file (the rail's
    # per-file accept); membership in the worktree's actual dirt is the path guard.
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    message = (d.get("message") or "").strip()
    path = (d.get("path") or "").strip()
    if not branch or not message:
        req._send(400, json.dumps({"ok": False, "err": "branch and message required"}))
        return
    wt = _worktree_for_branch(branch)
    if not wt:
        req._send(400, json.dumps({"ok": False, "err": f"{branch!r} is not checked out in any worktree"}))
        return
    if path and path not in _dirty_paths_of(wt):
        req._send(400, json.dumps({"ok": False, "err": f"{path!r} isn't a dirty path in that worktree"}))
        return
    add_r = ctx.run(["git", "-C", wt, "add", "-A", *(["--", path] if path else [])])
    if add_r.returncode != 0:
        req._send(500, json.dumps({"ok": False, "err": add_r.stderr or "git add failed"}))
        return
    commit_r = ctx.run(["git", "-C", wt, "commit", "-m", message, *(["--", path] if path else [])])
    if commit_r.returncode != 0:
        req._send(500, json.dumps({"ok": False, "err": commit_r.stderr or "git commit failed"}))
        return
    req._send(200, json.dumps({"ok": True}))


def discard_dirty(req, raw):
    # {branch, path} — the rail's per-file reject: a tracked file restores to HEAD, an
    # untracked one is deleted. Destructive by design (the UI arms it); path must be a
    # member of the worktree's actual dirt and resolve inside the worktree.
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    path = (d.get("path") or "").strip()
    if not branch or not path:
        req._send(400, json.dumps({"ok": False, "err": "branch and path required"}))
        return
    wt = _worktree_for_branch(branch)
    if not wt:
        req._send(400, json.dumps({"ok": False, "err": f"{branch!r} is not checked out in any worktree"}))
        return
    if path not in _dirty_paths_of(wt):
        req._send(400, json.dumps({"ok": False, "err": f"{path!r} isn't a dirty path in that worktree"}))
        return
    tracked = ctx.run(["git", "-C", wt, "ls-files", "--error-unmatch", "--", path]).returncode == 0
    if tracked:
        r = ctx.run(["git", "-C", wt, "restore", "--staged", "--worktree", "--", path])
        if r.returncode != 0:
            req._send(500, json.dumps({"ok": False, "err": r.stderr or "restore failed"}))
            return
    else:
        fp = os.path.realpath(os.path.join(wt, path))
        if not fp.startswith(os.path.realpath(wt) + os.sep):
            req._send(400, json.dumps({"ok": False, "err": "path escapes the worktree"}))
            return
        try:
            os.remove(fp)
        except OSError as e:
            req._send(500, json.dumps({"ok": False, "err": str(e)}))
            return
    req._send(200, json.dumps({"ok": True, "discarded": path, "was": "tracked" if tracked else "untracked"}))


def squash(req, raw):
    d = json.loads(raw or "{}")
    # squash button → collapse parent..branch into UNSTAGED working-tree changes, no commit
    # (Phil writes the commit in GitHub Desktop). See stack-squash --unstage.
    # --unpushed for the same reason /prep passes it: without it this collapsed to the frozen
    # fork-point even on a published branch, swallowing pushed commits and diverging the PR.
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-squash"), "--unstage", "--unpushed", d.get("branch", "")])
    # stack-squash always prints a JSON report (on success AND handled failure)
    req._send(200 if r.returncode == 0 else 500,
              r.stdout or json.dumps({"ok": False, "err": r.stderr or "squash crashed"}))


def prep(req, raw):
    d = json.loads(raw or "{}")
    # prep-for-push squash → smart subject, NO body (Phil's preference for squashed commits).
    # --unpushed: collapse only the commits past the branch's upstream, so an already-pushed branch
    # stays a fast-forward (no divergence / force-push surprise in GitHub Desktop). An unpushed branch
    # has no upstream, so stack-squash falls back to the frozen fork-point — the whole branch, as before.
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-squash"),
                 "--unpushed", "--format", "--subject-only", d.get("branch", "")])
    req._send(200 if r.returncode == 0 else 500,
              r.stdout or json.dumps({"ok": False, "err": r.stderr or "prep crashed"}))
