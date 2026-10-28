# srv/chat.py — "chat about this file", streamed into the browser. Runs a headless,
# READ-ONLY `claude -p` in the branch's worktree and proxies its stream-json output to
# the page as Server-Sent Events, so answer tokens land live instead of all-at-once.
# Multi-turn is stateless here: the client keeps the session_id we report (at stream start,
# repeated on `done`) and sends it back as `resume` for the next turn (so follow-ups keep the file
# context without us re-sending the diff).
#
#   POST /chat {branch, path?, patch?, question, resume?}  → text/event-stream
#     (mail-map-serve proxies its Q&A here)
#     (omit path → chat about the whole branch; the server computes its parent…branch diff)
#     event: session data: {"session_id":"…"}        # sent ASAP so a cut-short chat resumes
#     event: status data: {"s":"starting|thinking|writing"}
#     event: token  data: {"t":"…"}                  # an answer text delta
#     event: done   data: {"ok":true,"session_id":"…"}
#     event: error  data: {"err":"…"}
#
# Safety: an allowlist of read-only tools (Read/Grep/Glob) — headless claude can't prompt
# for anything outside it, so it can look around the branch but never edit/run/commit. Each
# turn is a run (srv/runs.py) in its own process group: closing the stream or restarting the
# server leaves it running, and a reconnect replays it from disk.
import json
import threading
import time

from . import ctx, prompts, runs


READ_ONLY_TOOLS = ["Read", "Grep", "Glob"]
def _node_diff(branch):
    # capped parent…branch diff so the model can read a real implementation detail per node
    parent = (ctx.run(["git", "config", f"branch.{branch}.stack-parent"]).stdout.strip()
              or ctx.run(["git", "config", f"stack-branch.{branch}.parent"]).stdout.strip() or "main")
    out = ctx.run(["git", "diff", f"{parent}...{branch}"]).stdout
    return out[:3500]


def _project_branches(project):
    # the project's member branches (stack-project.<p>.branch multivar), order preserved, deduped
    raw = ctx.run(["git", "config", "--get-all", f"stack-project.{project}.branch"]).stdout.split()
    seen, out = set(), []
    for b in raw:
        if b and b not in seen:
            seen.add(b)
            out.append(b)
    return out


def _project_integrator(project):
    # the fan-in branch carries every base via `requires`, so its worktree sees the whole feature —
    # the right cwd for read-only Read/Grep. Fall back to the first member, else the main checkout.
    branches = _project_branches(project)
    for b in branches:
        if (ctx.run(["git", "config", "--get-all", f"branch.{b}.stack-requires"]).stdout.strip()
                or ctx.run(["git", "config", "--get-all", f"stack-branch.{b}.requires"]).stdout.strip()):
            return b
    return branches[0] if branches else ""


# The whole-forest seed: an edge list (structure at a glance) then per-branch purpose + parent +
# requires + capped diff. Same multi-branch gather shape as merge_subjects, reusing _node_diff.
def _project_seed(project):
    branches = _project_branches(project)
    edges, blocks = [], []
    for b in branches:
        parent = (ctx.run(["git", "config", f"branch.{b}.stack-parent"]).stdout.strip()
                  or ctx.run(["git", "config", f"stack-branch.{b}.parent"]).stdout.strip() or "main")
        requires = (ctx.run(["git", "config", "--get-all", f"branch.{b}.stack-requires"]).stdout.split()
                    or ctx.run(["git", "config", "--get-all", f"stack-branch.{b}.requires"]).stdout.split())
        purpose = ctx.run(["git", "config", f"branch.{b}.description"]).stdout.strip()
        req = f"; requires: {', '.join(requires)}" if requires else ""
        edges.append(f"- {b}  (parent: {parent}{req})")
        blocks.append(
            f"### {b}\nPURPOSE: {purpose or '(none set)'}\nPARENT: {parent}\n"
            + (f"REQUIRES: {', '.join(requires)}\n" if requires else "")
            + f"DIFF (capped):\n{_node_diff(b)}"
        )
    return "EDGES:\n" + "\n".join(edges) + "\n\n" + "\n\n".join(blocks)


# Model aliases the chat may use — resolved to current models by the claude CLI, so no dated
# IDs to rot. Anything else from the client falls back to the default (never passed raw to --model).
ALLOWED_MODELS = {"opus", "sonnet", "haiku"}
DEFAULT_MODEL = "sonnet"


def _worktree_for(branch):
    # The worktree that currently holds this branch, so Read/Grep see the branch's tree
    # (not the main checkout, which may be on something else). None → fall back to CWD.
    out = ctx.run(["git", "worktree", "list", "--porcelain"]).stdout
    cur = None
    for line in out.splitlines():
        if line.startswith("worktree "):
            cur = line[9:]
        elif line.startswith("branch ") and line[7:].strip() == f"refs/heads/{branch}":
            return cur
    return None


# The branch's combined review diff (parent…branch), computed server-side so the page doesn't
# have to ship the whole thing. Capped — headless claude can Read individual files for the rest.
def _branch_diff(branch):
    parent = (ctx.run(["git", "config", f"branch.{branch}.stack-parent"]).stdout.strip()
              or ctx.run(["git", "config", f"stack-branch.{branch}.parent"]).stdout.strip() or "main")
    out = ctx.run(["git", "diff", f"{parent}...{branch}"]).stdout
    cap = 80_000
    if len(out) > cap:
        out = out[:cap] + f"\n\n… (diff truncated at {cap} chars — use Read on individual files for the rest)"
    return out


# ── turns ─────────────────────────────────────────────────────────────────
# A turn is a run (srv/runs.py, kind "turn", keyed by the client's turn id): claude writes its
# stream-json straight into the run's directory, so neither a closed tab nor a server restart
# touches it. A Job is this server image's FOLLOWER of that file — it replays it from the start
# and tails it into the SSE events the clients read. A request (the first one or a reconnect)
# SUBSCRIBES to the follower; an image that never saw the turn rebuilds the follower from disk.
_JOBS = {}
_JOBS_LOCK = threading.Lock()
JOB_TTL = 1800        # keep a finished job's buffer this long for a late reconnect (seconds)
MAX_JOBS = 60         # bound memory; oldest FINISHED jobs evicted first (running ones never)
RUNS_KEPT = 3 * 86_400
STREAM, STDERR = "stream.jsonl", "stderr.log"


class Job:
    def __init__(self, meta=None):
        self.events = []          # [(event, obj)] — the full SSE log, replayable from 0
        self.done = False
        self.ok = None            # terminal verdict — None while still running
        self.status = "starting"
        self.chars = 0            # answer characters streamed so far — the progress signal
        self.meta = meta or {}    # branch/path/question/repo/project — where this chat lives
        self.session_id = ""
        self.run = None
        self.created = time.time()
        self.cond = threading.Condition()

    @property
    def stopped(self):
        """The reader asked for the kill — its exit is an ending, not a failure."""
        return bool(self.run and self.run.marked("stopped"))

    def emit(self, event, obj):
        with self.cond:
            self.events.append((event, obj))
            if event == "session":
                self.session_id = obj.get("session_id", self.session_id)
            elif event == "token":
                self.chars += len(obj.get("t", ""))
            elif event == "status":
                self.status = obj.get("s", self.status)
            if event in ("done", "error"):
                self.done = True
                self.ok = bool(obj.get("ok")) if event == "done" else False
                self.status = "done" if event == "done" else "error"
            self.cond.notify_all()


def _prune(jobs):
    # caller holds _JOBS_LOCK. Drop finished followers past their TTL, then, if still over budget,
    # the oldest finished ones. A running one is never evicted; its run stays on disk either way.
    now = time.time()
    for tid in [t for t, j in jobs.items() if j.done and now - j.created > JOB_TTL]:
        del jobs[tid]
    if len(jobs) > MAX_JOBS:
        finished = sorted((j.created, t) for t, j in jobs.items() if j.done)
        for _, tid in finished[: len(jobs) - MAX_JOBS]:
            del jobs[tid]


# What a tool call is ABOUT, for the one-line activity trace: the input key that best names
# the target, per tool. Everything else falls back to the first short string value.
_TOOL_ARG_KEYS = {"Read": "file_path", "Edit": "file_path", "Write": "file_path",
                  "Bash": "command", "Grep": "pattern", "Glob": "pattern"}


def _tool_arg(name, inp):
    v = inp.get(_TOOL_ARG_KEYS.get(name, ""), "")
    if not isinstance(v, str) or not v:
        v = next((x for x in inp.values() if isinstance(x, str) and x), "")
    v = " ".join(v.split())
    return v[:120] + ("…" if len(v) > 120 else "")


def claude_events(ev, st):
    """One line of `claude -p --output-format stream-json` as the SSE events the clients read.
    `st` carries what earlier lines decided (whether a text block came before, the session id)."""
    out = []
    t = ev.get("type")
    if t == "system" and ev.get("subtype") == "init":
        if ev.get("session_id"):
            st["session"] = ev["session_id"]
            out.append(("session", {"session_id": ev["session_id"]}))
    elif t == "stream_event":
        e = ev.get("event", {})
        et = e.get("type")
        if et == "content_block_delta":
            delta = e.get("delta", {})
            if delta.get("type") == "text_delta":
                out.append(("token", {"t": delta.get("text", "")}))
                st["text"] = True
            elif delta.get("type") == "thinking_delta":
                out.append(("status", {"s": "thinking"}))
        elif et == "content_block_start" and e.get("content_block", {}).get("type") == "text":
            # claude interleaves text→tool→text as separate blocks; their deltas carry no space
            # across the join, so a later block glues onto the prior sentence ("…precisely.Now…")
            if st.get("text"):
                out.append(("token", {"t": "\n\n"}))
            out.append(("status", {"s": "writing"}))
    elif t == "assistant":
        # each completed assistant message carries its tool_use blocks with FULL input (the partial
        # stream only has empty inputs) — one activity line per call, so a watcher sees what it does
        for block in ev.get("message", {}).get("content", []):
            if isinstance(block, dict) and block.get("type") == "tool_use":
                name = block.get("name", "")
                out.append(("tool", {"name": name, "arg": _tool_arg(name, block.get("input") or {})}))
    elif t == "result":
        out.append(("done", {"ok": not ev.get("is_error"), "session_id": st.get("session", "")}))
    return out


def _follow(job, run):
    """Replay the run's stream from the start, then tail it until the process is gone."""
    st, off, buf = {}, 0, b""
    job.emit("status", {"s": "starting"})
    try:
        while True:
            over = not run.alive()   # judged BEFORE the read, so the last read takes the tail
            data, off = run.read(STREAM, off)
            *lines, buf = (buf + data).split(b"\n")
            for ln in lines:
                try:
                    ev = json.loads(ln)
                except ValueError:
                    continue
                for event, obj in claude_events(ev, st):
                    job.emit(event, obj)
            if over:
                break
            time.sleep(0.1)
        if job.done or job.stopped:
            return
        code = run.exit_code()
        err = run.read(STDERR)[0].decode(errors="replace").strip()[-400:]
        job.emit("error", {"err": err or (f"claude exited {code}" if code else "the turn's process died before it answered")})
    except Exception as e:   # a follower must never die silently — surface it to subscribers
        if not job.done:
            job.emit("error", {"err": str(e)[:400]})
    finally:
        # a natural end OR a stop → one terminal frame, so every subscriber unblocks
        if not job.done:
            job.emit("done", {"ok": True, "session_id": job.session_id, **({"stopped": True} if job.stopped else {})})


def _watch(job, run, jobs, key):
    job.run = run
    job.created = run.started
    jobs[key] = job
    threading.Thread(target=_follow, args=(job, run), daemon=True).start()
    return job


def attach(jobs, key, make):
    """The follower of turn `key`: this image's, else one rebuilt from its run on disk, else None.
    `make(meta)` builds the Job from the meta the turn was launched with. Caller holds _JOBS_LOCK."""
    job = jobs.get(key)
    if job is None:
        run = runs.find("turn", key)
        if run:
            job = _watch(make(run.meta), run, jobs, key)
    return job


def launch(jobs, key, make, cmd, cwd, meta):
    """Start turn `key` (a live one is joined, never doubled). Caller holds _JOBS_LOCK."""
    try:
        run = runs.start("turn", key, cmd, cwd, meta=meta, out=STREAM, err=STDERR)
    except runs.Busy:
        jobs.pop(key, None)
        return attach(jobs, key, make)
    _prune(jobs)
    runs.prune("turn", RUNS_KEPT)
    return _watch(make(meta), run, jobs, key)


def _subscribe(req, job, from_idx=0):
    req.send_response(200)
    req.send_header("Content-Type", "text/event-stream")
    req.send_header("Cache-Control", "no-store")
    req.send_header("Connection", "keep-alive")
    req.end_headers()
    i = from_idx
    try:
        while True:
            with job.cond:
                while i >= len(job.events) and not job.done:
                    job.cond.wait(timeout=15)
                batch = job.events[i:]
                i = len(job.events)
                done = job.done
            for event, obj in batch:
                req.wfile.write(f"event: {event}\ndata: {json.dumps(obj)}\n\n".encode())
            if not batch:
                req.wfile.write(b": ping\n\n")   # keepalive while idle (long thinking, no tokens yet)
            req.wfile.flush()
            if done and i >= len(job.events):
                break
    except (OSError, BrokenPipeError):
        pass   # THIS subscriber dropped (tab closed) — the job keeps running for a reconnect


def start(req, raw):
    d = json.loads(raw or "{}")
    branch = (d.get("branch") or "").strip()
    project = (d.get("project") or "").strip()
    path = (d.get("path") or "").strip()
    question = (d.get("question") or "").strip()
    resume = (d.get("resume") or "").strip()
    turn = (d.get("turn") or "").strip()
    model = (d.get("model") or "").strip()
    if model not in ALLOWED_MODELS:
        model = DEFAULT_MODEL
    if not turn or not (branch or project):
        req._send(400, json.dumps({"ok": False, "err": "need a branch or project + turn"}))
        return

    with _JOBS_LOCK:
        job = attach(_JOBS, turn, lambda m: Job(m.get("job")))
    # A reconnect (no question) to a turn with no run on disk — pruned. Tell the client so it falls
    # back to --resume from the session id it already persisted.
    if job is None and not question:
        req.send_response(200)
        req.send_header("Content-Type", "text/event-stream")
        req.send_header("Cache-Control", "no-store")
        req.end_headers()
        try:
            req.wfile.write(b"event: gone\ndata: {}\n\n")
            req.wfile.flush()
        except (OSError, BrokenPipeError):
            pass
        return

    if job is None:
        # Build the command OUTSIDE the lock (prompt building can do git I/O), then create under
        # the lock with a double-check so two concurrent reconnects don't double-spawn the turn.
        # A resumed turn already carries its context — just send the question. A fresh turn seeds
        # the diff + ground rules: one file when a path is given, else the whole branch.
        if resume:
            prompt = question
        elif project:
            prompt = prompts.project_chat(project, _project_seed(project), question)
        elif path:
            prompt = prompts.file_chat(branch, path, d.get("patch", ""), question)
        else:
            prompt = prompts.branch_chat(branch, d.get("patch") or _branch_diff(branch), question)
        # a project chat runs in the integrator's worktree (it carries every base via requires)
        cwd = _worktree_for(branch or _project_integrator(project)) or ctx.CWD
        repo_dir = ctx.repo_cwd()
        meta = {
            "branch": branch, "path": path, "question": question[:120],
            "repo": next((n for n, p in ctx.REPOS.items() if p == repo_dir), ""),
            "project": (project or ctx.run(["git", "config", "--get", f"branch.{branch}.stack-project"]).stdout.strip()
                        or ctx.run(["git", "config", "--get", f"stack-branch.{branch}.project"]).stdout.strip()),
        }
        cmd = ["claude", "-p", prompt,
               "--output-format", "stream-json",
               "--include-partial-messages",
               "--verbose",
               "--model", model]
        if resume:
            cmd += ["--resume", resume]
        # variadic — keep it LAST so it doesn't swallow a following flag's value
        cmd += ["--allowedTools", *READ_ONLY_TOOLS]
        with _JOBS_LOCK:
            job = attach(_JOBS, turn, lambda m: Job(m.get("job"))) or \
                launch(_JOBS, turn, lambda m: Job(m.get("job")), cmd, cwd, {"job": meta})

    _subscribe(req, job, 0)
